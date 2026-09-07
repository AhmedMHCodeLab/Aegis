# ADR: A bootstrap layer for resources GCP will not let Terraform destroy

**Status:** Accepted
**Scope:** `terraform/bootstrap/`, `terraform/data.tf`, `modules/security`, `modules/iam`, `modules/binary_authorization`
**Supersedes:** the single-root layout in which every resource shared one lifecycle

## Context

`terraform destroy` followed by `terraform apply` did not round trip. The second
apply failed with:

```
Error 409: Requested entity already exists
  module.iam.google_iam_workload_identity_pool.github

Error 409: KeyRing projects/aegis-prod-0926/locations/me-central1/keyRings/aegis
  already exists.
  module.security.google_kms_key_ring.main
```

These are not transient. They are two GCP behaviours that the single-root layout
had no way to express.

**KMS key rings and crypto keys have no delete API.** The provider documentation
states it plainly: "KeyRings cannot be deleted from Google Cloud Platform.
Destroying a Terraform-managed KeyRing will remove it from state but *will not
delete the resource from the project*." The same holds for crypto keys; only key
*versions* can be destroyed. So destroy silently drops them from state, apply
tries to create them, and GCP returns 409. Forever.

That last clause is the trap, and it is worse than it first appears. Destroying a
crypto key cannot delete the key, but it *does* schedule every version for
destruction. The key survives the destroy in a state where it cannot be used:

```
Error 400: .../cryptoKeys/aegis-attestor/cryptoKeyVersions/1 is not enabled,
current state is: DESTROY_SCHEDULED
```

So a destroy leaves KMS in the worst of both worlds. The resources block a
recreate because they still exist, and they simultaneously refuse to work because
their versions are on death row. Recovery is `restore` (which returns the version
to DISABLED, not ENABLED) followed by `enable`, and only within the key's
`destroy_scheduled_duration`, 30 days by default. Past that the version is gone,
and with it everything encrypted under it.

**Workload Identity Pools and providers are soft-deleted for ~30 days.** During
that window the ID stays reserved and cannot be reused. The pool can be restored
with `undelete`, but it cannot be recreated under the same name.

The stack therefore contained five resources that could be created once and never
cleanly recreated, mixed in with about seventy that rebuild fine.

## The choice this forces

A configuration cannot be both "fully destroyable" and "contains a KMS key ring".
GCP does not permit it. The only question is where the seam goes.

**Randomise the names.** Suffix the key ring and pool with a `random_id` so each
rebuild creates fresh ones. Rebuilds become clean with no imports at all.
Rejected because every rebuild leaves behind a key ring that can never be deleted,
so the project accumulates permanent garbage, and the WIF provider name changes on
every rebuild, which means `ci.yml` has to be regenerated each time.

**Repair after each destroy.** Keep one root and run a script that undeletes and
reimports the five resources before each apply. Rejected as the default: it works,
but it makes every rebuild depend on remembering a step, and the failure mode when
you forget is a 409 that looks like a bug rather than a missing procedure.

**Split by lifecycle.** Chosen. The five permanent resources move to
`terraform/bootstrap/`, applied once and never destroyed. The main configuration
reads them as data sources.

## Decision

```
terraform/bootstrap/     applied once, never destroyed
  key ring
  aegis-key              CMEK for images, revisions, secrets
  aegis-attestor         Binary Authorization signing key
  WIF pool + provider
  aegis-lb-ip            reserved global address behind the DNS A record

terraform/               destroy and apply freely
  data "google_kms_key_ring" "main"          {...}
  data "google_kms_crypto_key" "main"        {...}
  data "google_kms_crypto_key" "attestor"    {...}
  data "google_iam_workload_identity_pool" "github" {...}
  everything else
```

Separate state (`terraform/bootstrap` prefix in the same GCS bucket), so a
destroy of the main stack cannot touch it.

Every bootstrap resource carries `prevent_destroy = true`. For the KMS resources
this is not decoration: GCP refuses to delete the key ring and key, but it will
happily schedule their versions for destruction, so `prevent_destroy` is what
stops a destroy from quietly rendering the CMEK key unusable and taking every
CMEK-encrypted resource with it. For the WIF pool it is a genuine choice: the pool
*can* be deleted, but deleting it re-enters the 30-day reservation trap, so the
layer refuses.

## The charter widened once, deliberately

The layer was originally justified by a hard constraint: GCP physically refuses to
recreate these resources. The reserved global address does not meet that bar. It
deletes and recreates perfectly well.

It was added anyway, on a second and weaker criterion: **external systems point at
it.** A rebuild reallocates the address, and the DNS A record silently keeps
pointing at an IP that no longer exists. The managed certificate then reports
`FAILED_NOT_VISIBLE`, the domain stops resolving to anything, and the only repair
is a human noticing and editing DNS by hand. That is precisely the class of
undocumented manual step this project is supposed to eliminate, and it recurs on
every single teardown.

This is worth stating plainly because it is a slope. "GCP will not let me recreate
this" is objective and admits few members. "Something outside Terraform depends on
this being stable" is a judgement call, and almost any resource can be argued into
it. The test applied here, and the one to apply next time: does an external system
hold a reference that breaks silently, and is repairing it manual? Both true for
the IP. Neither is true for, say, the Cloud Run service or the backend service,
which are addressed by name rather than by a value someone copied elsewhere.

## Consequences

**The IAM bindings stayed in the main configuration**, not in bootstrap, even
though they grant on bootstrap-owned keys. `google_kms_crypto_key_iam_member` and
the service-agent identities can be deleted and recreated normally, so they belong
with the lifecycle that rebuilds. Bootstrap owns the key; the main stack owns who
may use it.

**The service accounts stayed in the main configuration.** They are soft-deleted
like WIF pools, but unlike WIF pools the name can be reused immediately: a
recreated SA gets the same email and a new unique ID. Confirmed empirically, as
the failing apply that produced the 409s above created both `aegis-run` and
`aegis-ci` without complaint.

**Cost: a second root and a second state file.** Bootstrap is applied by hand and
is not wired into `terraform.yml`, because a workflow that can apply it is a
workflow that can be pointed at destroying it.

**`prevent_destroy` is now honest.** It was previously set to `false` so that
destroy would not error, which meant the code claimed the keys were disposable
while GCP treated them as permanent. Checkov `CKV_GCP_82` was being skipped to
paper over that; the skip is now removed and the check passes.

## What would cause reconsideration

- Google shipping a delete API for key rings, which would collapse this back to
  one root.
- A second environment, at which point bootstrap needs either a workspace per
  environment or a name prefix, since key ring names are permanent per project
  and cannot be recycled between environments.

## Sources consulted

- Terraform provider, `google_kms_key_ring` — "KeyRings cannot be deleted from
  Google Cloud Platform"
- Cloud KMS, *Destroy and restore key versions* — `DESTROY_SCHEDULED` restores to
  DISABLED, not ENABLED, and only within `destroy_scheduled_duration`
- Cloud KMS, *Key version states* — a scheduled version cannot serve cryptographic
  operations
- IAM REST reference, `projects.locations.workloadIdentityPools.delete` — soft
  delete, ~30 day retention, ID reserved until permanent deletion
- `gcloud iam workload-identity-pools undelete` — restore within the window
