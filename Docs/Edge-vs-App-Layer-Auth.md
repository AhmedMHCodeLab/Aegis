# ADR: The edge authorises, the application verifies the assertion

**Status:** Accepted
**Scope:** `app/src/main.py`, `terraform/modules/security/`
**Addresses:** Threat model T-02

## Context

The project brief draws a scope boundary: "No authentication logic inside the app (IAP owns this)". The
code honours it exactly. There is no middleware, no header inspection, no session handling, no user
model.

The threat model found the cost of that boundary taken literally. The application serves any request
that reaches its socket. It is correct only while the ingress restriction and invoker IAM hold perfectly
and permanently. If IAP is disabled during an incident, or a revision ships with `ingress = all`, or the
invoker binding is loosened, **the application cannot notice**. It keeps returning 200s, and nothing in
its logs separates an authenticated analyst from an anonymous caller. The failure is silent, which is
the property that makes it worth treating.

Google documents the answer and the reason. IAP adds `x-goog-iap-jwt-assertion`, and "Signed headers
provide secondary security in case someone bypasses IAP. When IAP is enabled, IAP strips the `x-goog-*`
headers provided by the client." Without verification, "if an attacker bypasses IAP, the attacker can
forge the IAP unsigned identity headers, `x-goog-authenticated-user-{email,id}`"
([source](https://docs.cloud.google.com/iap/docs/signed-headers-howto)).

## Decision

**Authorization stays at the edge. The application verifies the IAP JWT signature, gated on an
`IAP_AUDIENCE` environment variable.**

The distinction the brief's boundary was protecting is preserved, because verification is not
authorization:

| Concern | Owner | In the app? |
|---|---|---|
| Who may access the service | IAP, `roles/iap.httpsResourceAccessor` | No |
| User accounts, roles, permissions | None exist | No |
| Sessions, cookies, login flows | IAP | No |
| Is this request proven to have come through IAP | Application | **Yes** |

The app makes no access decision and holds no user model. It refuses to trust an unauthenticated
network path. That is a different question from "who is allowed in", and only the second one was ever
IAP's exclusively.

**This is the project's own fail-closed principle applied to authentication.**
`Docs/Fail-Closed-Evaluation.md` establishes that absence of evidence is not evidence of compliance. An
absent or unverifiable signed assertion is not evidence that a request was authenticated. Accepting it
because the network usually delivers authenticated traffic is exactly the reasoning that ADR rejected
for compliance verdicts.

## Consequences

**One dependency added to a five-dependency application.** `google-auth`, for signature verification
against Google's public keys. Measured against a distroless image whose entire argument is minimal
surface, this is a real cost and not a rounding error.

**Configuration becomes load-bearing.** `IAP_AUDIENCE` set means enforce; unset means skip. That gate
preserves the brief's local development property: `docker run` with zero GCP credentials still works,
which is how the app is demonstrated and tested.

**The gate is also the weakness.** An unset variable in production silently disables the control. It
fails open, which is the opposite of the principle motivating it. Mitigated by asserting the variable's
presence in the Terraform service definition rather than leaving it to the deployer, so the failure mode
is a failed apply rather than a quietly unprotected service.

**T-02 drops from Medium to Low residual risk.** It does not reach zero: a bypass still requires T-01's
controls to have failed first, and this control detects rather than prevents that.

## Alternatives rejected

**No verification, edge only.** The brief's literal position, and the cheapest. Zero dependencies, zero
config. Rejected because it makes a silent failure mode permanent: there is no state of the world in
which the application can report that it was reached without IAP. Carried as accepted Medium residual
risk if this ADR is ever reversed.

**Full application-layer authorization.** Parse the identity, maintain a user table, enforce
per-user rules in the app. Rejected: it duplicates IAP, creates two authorization policies that will
diverge, and adds exactly the auth logic the brief excluded for good reason. Aegis has no per-user
resources to authorise against.

**Verify only when the header is present.** Superficially convenient. Rejected because it fails open by
construction: an attacker bypassing IAP simply omits the header. The env gate moves the decision to
deploy time, where it is auditable, instead of request time, where it is attacker-controlled.

## Remaining uncertainty

The audience string format for a backend-service IAP deployment. It is confirmed at deploy time from
the backend service ID, not written from memory.

## Verification

- A request to the Cloud Run URL carrying a forged `x-goog-authenticated-user-email` and no valid
  assertion is rejected
- A request through the LB from an authorised user succeeds
- `docker run` with `IAP_AUDIENCE` unset serves the UI locally with no credentials
- Terraform plan fails if the audience is not supplied to the service definition
