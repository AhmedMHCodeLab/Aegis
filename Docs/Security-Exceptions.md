# Security exceptions

Controls the design calls for that are **not deployed**, and gates that pass by
suppression rather than by being clean. Each entry states what is missing, why,
what risk is actually carried, and what would close it.

This exists because the alternative is worse: a threat model naming controls that
do not exist, and green pipeline badges over suppressed findings. A reviewer
should be able to find the gap here rather than discover it in the console.

---

## 1. Cloud Armor is not deployed

**Status:** absent. No WAF, no rate limiting, no security policy of any kind.

`enable_cloud_armor` defaults to `false` in the `dns` module, and the root
configuration does not override it. The load balancer, the managed certificate and
the RESTRICTED TLS 1.2 policy are unaffected and do work.

**Why.** All three Cloud Armor quotas on this project are zero:

```
SECURITY_POLICIES           = 0
SECURITY_POLICY_RULES       = 0
SECURITY_POLICY_CEVAL_RULES = 0
```

A request for the smallest usable value was **denied immediately** rather than
queued, with `'0' was granted`. That is an account-level restriction, not a sizing
decision. The billing account originated as a free trial; Cloud Armor quotas are
zero during a trial and do not lift automatically on upgrade to paid, and Google's
automated quota system weighs billing history and account age, which a recently
upgraded account fails. There is no self-service path left, only a Cloud Billing
Support case for manual review.

**Risk actually carried.**

| Threat | What Cloud Armor was going to do | What actually holds the line |
|---|---|---|
| T-03 DOM XSS | XSS signatures as defence in depth | `fmt()` output escaping, which was always the real control. The WAF was never load-bearing here: it inspects requests and the sink is in the response |
| T-04 cost amplification | 100 req/min per IP throttle | IAP reduces callers to a one-person allowlist, and `max_instance_count` is the actual cost ceiling. Rate limiting is gone entirely |
| SQL injection | `sqli-v33-stable` | Nothing, and nothing is needed: there is no database and no SQL driver |

The honest summary is that the loss is **rate limiting**, and it is real but
bounded by IAP standing in front of everything. An authorised caller can hammer
the service; an unauthenticated one cannot reach it. XSS and SQLi coverage were
already documented in the threat model as either not load-bearing or not
applicable, so their absence changes little.

**What would close it.** Cloud Billing Support granting quota, after which
`enable_cloud_armor = true` deploys the policy that is already written.

---

## 2. Container OS vulnerabilities are suppressed

**Status:** the OS layer of the image is effectively unscanned.

`.trivyignore` lists 22 CVEs and the workflow passes `ignore-unfixed: true`.
Between them, essentially every finding in the base image is suppressed, including
two rated CRITICAL:

- `CVE-2023-45853` (zlib, `will_not_fix`)
- `CVE-2025-7458` (sqlite, `will_not_fix`)

**Why.** Every one is an OS package inside
`gcr.io/distroless/python3-debian12:nonroot`. Distroless ships no package manager,
so they cannot be patched from our Dockerfile. They fall in three groups: Debian
declines to fix them, no fix exists yet, or Debian has fixed them and the
distroless image has not yet rebuilt against the update.

**Risk actually carried.** Real but hard to action. The application's own
dependencies are clean, which is the part we control. Reachability is low for most
of these: the service parses JSON and YAML and does not use sqlite, XML or
Kerberos. Neither CRITICAL is reachable from any code path Aegis executes.

**What is not true.** The pipeline's Trivy gate should not be read as "the image
has no HIGH or CRITICAL vulnerabilities". It means "no findings outside the
suppression list", and the suppression list is most of the OS.

**What would close it.** Google rebuilding the distroless base against current
Debian, then repinning the digest and pruning `.trivyignore` to whatever survives.
The ignore file is pinned to a specific base digest and should be re-derived, not
carried forward, whenever that digest changes.

---

## 3. Three IaC policy checks are skipped

**Status:** `terraform/.checkov.yaml` skips three checks. Checkov reports clean
because of the skips, not in spite of them.

| Check | What it wants | Why skipped |
|---|---|---|
| `CKV_GCP_26` | VPC Flow Logs on every subnet | The subnet carries only Cloud Run direct egress to `restricted.googleapis.com`, behind a default-deny rule with a single pinhole. Flow logs would bill continuously to record traffic to one destination. **This is a judgement call, and it does cost forensic capability**: if egress is ever misused, there is no flow record |
| `CKV_GCP_49` | No project-level roles that manage service accounts | `aegis-ci` holds `roles/iam.serviceAccountAdmin` because Terraform manages the service accounts. The check is correct that this is powerful. What bounds it is WIF restricting impersonation to this repository on `refs/heads/main`, plus the `production-infra` approval gate on apply |
| `CKV_GCP_125` | Stricter GitHub OIDC trust policy | The provider already pins `assertion.repository_owner_id` numerically and `assertion.ref` to `refs/heads/main`. **The specific condition Checkov tests for was not verified against its source**, so this skip rests on the binding looking correct rather than on confirming what the rule wants |

`CKV_GCP_49` is the one worth revisiting. CI now holds fourteen project-level
roles, and the count grew by one during deployment without a deliberate review of
the whole set.

---

## 4. Deferred from the threat model

Carried over and still open:

- **No request body size cap.** T-03 and T-04 both cite it. A 200,029-byte body was
  accepted and fully evaluated. This mattered more when Cloud Armor was expected to
  inspect bodies; with no WAF at all, the cap is now the only request-size control
  there would be, so its absence is more significant than when it was deferred.
- **No Content Security Policy.** T-03 lists it as deferred defence in depth behind
  `fmt()` escaping.

---

## Review triggers

Re-read this document when any of these change:

- The distroless base image digest, which invalidates `.trivyignore`
- Cloud Armor quota being granted
- Any new entry in `ci_project_roles`
- A second deployable service, which changes what the IAP allowlist and the
  Binary Authorization default rule cover
