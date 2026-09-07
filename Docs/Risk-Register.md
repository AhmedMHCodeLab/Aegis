# Risk Register: Aegis Compliance Checkpoint

**Status:** Session 1. Re-validate after Sessions 2 and 3.
**Source:** `Docs/Threat-Model.md` (T-01 through T-08), plus two operational risks surfaced during threat modelling.

## Rating scale

| Level | Meaning |
|---|---|
| Critical | Service compromise, credential exposure, or client data exfiltration |
| High | Bypass of a primary security boundary or uncontrolled spend |
| Medium | Degraded control, exploitable by an authenticated or positioned attacker |
| Low | Requires chained failures or produces limited impact |

Residual risk is the rating **after** all committed controls are applied. No row carries "none".

## Register

| # | Risk | Threat | Inherent | Controls (summary) | Residual | Owner | Review trigger |
|---|---|---|---|---|---|---|---|
| R-01 | Direct invocation bypasses the entire edge (Cloud Armor, IAP, SSL policy, custom domain) | T-01 | High | IAP enabled directly on Cloud Run, protects both `run.app` and the LB path; invoker IAM restricted to IAP's own service agent (no `allUsers`) | **Low** | Infra (Session 2) | Any change to Cloud Run ingress or IAM bindings |
| R-02 | Application cannot distinguish authenticated from unauthenticated requests, fails silently if IAP is removed | T-02 | High | IAP JWT verification in app, env-gated on `IAP_AUDIENCE`; Terraform asserts the variable is set | **Low** | App + Infra | IAP configuration change; `IAP_AUDIENCE` env var removed or emptied |
| R-03 | Client-submitted configuration values execute as script in the analyst's browser (DOM XSS) | T-03 | High | `fmt()` output escaping (fixed); CSP (deferred); Cloud Armor XSS rules with JSON parsing (defence in depth); request size cap (Session 2) | **Medium** | App (fixed) + Infra (Session 2) | Any change to the findings render path; new `innerHTML` usage |
| R-04 | Unbounded request evaluation converts to billing via instance autoscaling | T-04 | Medium | IAP (reduces attackers to named allowlist); Cloud Armor rate limiting; `max_instance_count` ceiling; body size cap (Session 2); billing budget alert | **Medium** | Infra (Session 2) | `max_instance_count` change; billing alert threshold change; new endpoint added |
| R-05 | Client configuration leaks into logs, persisting data the service was designed not to store | T-05 | High | Metadata-only logging (implemented, verified); exception handler logs type and rule ID only; debug mode asserted off; scoped log access | **Low** | App (done) + Infra (Session 3) | Any change to logging statements; Starlette debug setting; new exception handler |
| R-06 | Compromised CI identity deploys attacker-controlled code and inherits runtime SA credentials | T-06 | Critical | WIF `attribute_condition` binding repo + ref; deploy-scoped CI SA; no SA keys; SHA-pinned actions; push-on-main triggers only; admin activity alert | **Medium** | CI/CD (Session 3) | WIF provider attribute change; new GitHub Actions workflow; CI SA role grant |
| R-07 | Compromised base image or dependency executes inside the container with the runtime SA's access | T-07 | High | Distroless image; Trivy CRITICAL gate; Bandit SAST; Artifact Registry CMEK. **Known gaps:** tag pinning (not digest), version pinning (not hash), no Binary Authorization | **Medium** | CI/CD (Session 3) | Base image update; dependency addition or version bump; Dockerfile change |
| R-08 | DNS compromise in AWS repoints traffic away from GCP, upstream of every GCP control | T-08 | High | AWS MFA, no long-lived Route 53 keys; registrar transfer lock; DNSSEC; GCP certificate state monitoring | **Medium** | AWS account owner | AWS account credential change; registrar transfer; certificate renewal failure alert |
| R-09 | Google-managed certificate fails renewal because DNS records no longer point exclusively at the LB IP | T-08 | Medium | Certificate state monitoring alert; documented requirement that the A record points only at the LB forwarding rule IP | **Medium** | Infra (Session 2) | Any A record change; LB IP change; certificate expiry approaching |
| R-10 | Free-trial budget exhaustion takes the entire project offline, not just the service | T-04 | Medium | `max_instance_count`; billing budget alert; IAP reducing the attacker population to named users | **Medium** | Infra (Session 2) | Billing alert fires; `max_instance_count` raised; new billable resource added |

## Reading the register

**Inherent** is the risk before any project-owned control. Google platform properties (GFE TLS termination, DDoS absorption, container runtime isolation) are already factored in because they are not ours to lose.

**Residual** is the risk after committed controls. "Committed" means designed and assigned to a session, not necessarily applied. Four of ten rows stay Medium after treatment, and each states why rather than averaging away. No row reaches zero because:

- R-01/R-02: IAP-direct + invoker IAM + JWT verification is strong. O-1 (cross-project LB admission) is now resolved, IAP's invoker restriction closes it regardless of which LB fronts the service
- R-03: output escaping is the fix, but CSP and the size cap are not yet applied
- R-04/R-10: IAP narrows the attacker set but a legitimate user can still trigger spend
- R-06: WIF conditions are correct but the repository is single-author with no enforced code review
- R-07: two known supply chain gaps (tag pinning, no admission control) are documented but not closed
- R-08/R-09: the cross-cloud control plane is a structural decision, not a gap to be closed

## Operational notes

R-09 is derived from T-08 but is a distinct failure mode: the DNS record is not compromised, just wrong. It surfaces during a routine infrastructure change (LB IP rotation, A record update for a second service) rather than an attack, and the symptom is a TLS outage days or weeks later when the cert renewal cycle fires.

R-10 is derived from T-04 but the blast radius is the project, not the service. On a free trial, budget exhaustion does not merely degrade Aegis; it suspends the GCP project, taking Terraform state access and the artifact registry with it.

## Session-gated items

| Item | Session | Why it is gated |
|---|---|---|
| Request size cap | 2 | Must be chosen alongside `--request-body-inspection-size` |
| CSP headers | 2 | Requires nonce generation or extraction of inline scripts |
| Digest pinning, dependency hash pinning | 3 | CI pipeline must exist before pinning strategy applies |
| Binary Authorization | 3+ | Requires attestor setup and is the next hardening step, not a Session 1 commitment |
| Certificate monitoring alert | 2 | Requires the LB and cert to exist |
