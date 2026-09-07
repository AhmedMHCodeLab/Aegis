# ADR: Two signatures on one image, keyless for provenance and KMS for admission

**Status:** Accepted
**Scope:** `terraform/modules/binary_authorization/`, `terraform/modules/cloud_run/`, `.github/workflows/ci.yml`
**Addresses:** Threat model supply chain path; the out-of-band deployment gap

## Context

The pipeline already signs every image with cosign and verifies that signature before
deploying:

```
build → Trivy → push → cosign sign → attest → cosign verify → deploy
```

That chain is sound, and it protects **the pipeline**. It does not protect **the
platform**. Every step above runs inside the workflow, so it constrains what the
workflow will deploy and nothing else. Any principal holding `roles/run.developer` on
the service can bypass CI entirely:

```bash
gcloud run deploy aegis --image=docker.io/attacker/anything
```

Cloud Run accepts that revision. No signature is consulted, because nothing in the
platform was ever asked to consult one. The verification step is a property of our
build script, not an admission control.

Binary Authorization is the control that closes this: it evaluates policy at the
admission layer, on every revision that takes traffic, regardless of who initiated
the deployment or which tool they used.

## The constraint that shaped the decision

Binary Authorization cannot verify the signature the pipeline already produces.

Cosign is used in **keyless** mode. Fulcio issues a short-lived certificate binding an
ephemeral key to the workflow's OIDC identity, and the signing event is recorded in
Rekor. There is no long-lived public key, which is the entire point: identity replaces
key custody.

Every Binary Authorization signature check is configured with a **stable public key**,
either embedded in a `sigstoreSignatureCheck` or held by an attestor. There is nowhere
to put an identity claim. The two mechanisms do not meet.

Two further findings, from Google's documentation:

- The Sigstore signature check is documented **only under continuous validation**,
  which logs violations after the fact and explicitly does not block a deployment. It
  also requires an ECDSA public key, typically from KMS.
- The deploy-time enforcement path that *is* documented uses **Grafeas attestation
  occurrences** signed with a PKIX or KMS key and verified by an attestor.

Whether `sigstoreSignatureCheck` also enforces at deploy time specifically on Cloud
Run is **not documented either way**. The REST reference lists it as a valid check
field with no platform restriction stated, but no Cloud Run guide confirms blocking
behaviour. This was not resolved, and the decision below does not depend on it.

## Alternatives

**Trusted directory check only.** A policy admitting only images whose path is under
our Artifact Registry repository. One policy object, no second signing path, and it
genuinely blocks the attack above, since an attacker would need
`artifactregistry.writer` on a CMEK-encrypted repository with immutable tags rather
than merely `run.developer`. Rejected because it asserts *where the image came from*,
not *that anyone approved it*. A compromised CI token could still push and deploy.

**Switch cosign to a KMS key.** One signing mechanism, verified by
`sigstoreSignatureCheck`. Rejected on two counts: it depends on the deploy-time
behaviour that could not be confirmed, and it discards what keyless is for. A KMS
signature says "something holding this key signed it". A keyless signature says "the
`ci.yml` workflow, in the `AhmedMHCodeLab/Aegis` repository, on `refs/heads/main`,
signed it", and says so to anyone, with no access to this GCP project, verifiable
against a public transparency log.

**Accept the gap.** Defensible if `run.developer` were held by nobody but CI. It is
not a position worth taking in a project whose subject matter is deployment
compliance.

## Decision

Keep keyless cosign, and additionally create a KMS-signed Grafeas attestation for
Binary Authorization to enforce against.

```
                    ┌── cosign keyless ──► public provenance claim
build → push ──►────┤                       (Fulcio identity + Rekor log)
                    │
                    └── KMS attestation ──► admission control
                                             (attestor verifies, policy blocks)
```

The image carries two proofs because they answer different questions for different
audiences:

| | Proves | Verifiable by | Enforced where |
|---|---|---|---|
| Cosign keyless | This workflow, in this repo, on this branch, built it | Anyone, no GCP access | Nowhere; it is evidence |
| KMS attestation | A holder of the attestor key approved this digest | This project | Cloud Run admission, blocking |

Both are bound to the **digest**, not a tag, so they refer to exactly the bytes that
were scanned.

## Trade-offs accepted

**Two signing paths for one artifact.** The honest cost. If the attestation step is
removed, enforcement silently continues passing on already-attested digests and fails
only on the next new image, which is a confusing failure mode. Mitigated only by the
fact that both steps live in the same job and fail loudly.

**The attestation is weaker than it looks.** It proves the CI service account signed
the digest, not that the pipeline's gates actually ran. Anyone who can impersonate
`aegis-ci` and use the key can attest an arbitrary image. The real strength is the
combination: WIF restricts impersonation to this repository on `main`, and the key
grants `signerVerifier` only, so CI can sign but cannot read, disable or destroy the
key.

**The bootstrap placeholder is admitted by pattern.** `us-docker.pkg.dev/cloudrun/container/*`
is allowlisted, because the registry is empty on first apply and Google's placeholder
is not ours to attest to. That pattern is a permanent hole, narrow but real: anything
Google publishes under it would be admitted. Acceptable because the alternative is a
service that cannot be created before its own first deployment.

**`prevent_destroy` on the attestor key.** Destroying it invalidates every existing
attestation and blocks all deployments until a new key, attestor and attestations
exist. Guarded deliberately.

## What would cause reconsideration

- Google documenting deploy-time `sigstoreSignatureCheck` support for Cloud Run, which
  would collapse this to one signing mechanism at the cost of the identity binding.
- Binary Authorization gaining support for keyless verification against a Fulcio
  identity, which would remove the need for the second signature entirely.
- Adding a second deployable service, at which point the policy should move from
  `default_admission_rule` to per-service rules rather than one project-wide default.

## Sources consulted

- Binary Authorization, *Use the Sigstore signature check* — continuous validation
  scope, public key requirement
- Binary Authorization, *Getting started with the CLI* — attestor model, PKIX and KMS
  key types, `attestations sign-and-create`
- Binary Authorization REST reference, `projects.platforms.policies` — the `Check`
  field list, and the absence of documented platform restrictions
- Cloud Run, *Use Binary Authorization* — deploy-time enforcement on revisions taking
  traffic
