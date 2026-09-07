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
| R-01 | Direct invocation bypasses the edge (IAP, SSL policy, custom domain) | T-01 | High | IAP enabled directly on Cloud Run, protects both `run.app` and the LB path; invoker IAM restricted to IAP's own service agent (no `allUsers`) | **Low** | Infra (Session 2) | Any change to Cloud Run ingress or IAM bindings |
| R-02 | Application cannot distinguish authenticated from unauthenticated requests, fails silently if IAP is removed | T-02 | High | **The designed control was never built.** There is no `IAP_AUDIENCE`, no JWT verification, and Terraform asserts nothing. What holds is platform-side only: Cloud Run invoker IAM granted solely to IAP's service agent, with no `allUsers`, so an unauthenticated caller cannot reach the container. The app itself trusts its caller unconditionally | **Medium** | App (not started) | IAP configuration change; any grant of `run.invoker` beyond the IAP service agent |
| R-03 | Client-submitted configuration values execute as script in the analyst's browser (DOM XSS) | T-03 | High | `fmt()` output escaping (fixed, and always the real control since the sink is response-side); CSP (deferred); request size cap (deferred). Cloud Armor XSS rules are **not deployed**, see [Security-Exceptions](Security-Exceptions.md) | **Medium** | App (fixed) + Infra (Session 2) | Any change to the findings render path; new `innerHTML` usage |
| R-04 | Unbounded request evaluation converts to billing via instance autoscaling | T-04 | Medium | IAP (reduces attackers to a one-person allowlist); `max_instance_count` ceiling, the actual cost ceiling; billing budget alert; body size cap (deferred). **No rate limiting of any kind**: Cloud Armor is not deployed, see [Security-Exceptions](Security-Exceptions.md) | **Medium** | Infra (Session 2) | `max_instance_count` change; billing alert threshold change; new endpoint added |
| R-05 | Client configuration leaks into logs, persisting data the service was designed not to store | T-05 | High | Metadata-only logging (implemented, verified); exception handler logs type and rule ID only; debug mode asserted off; scoped log access | **Low** | App (done) + Infra (Session 3) | Any change to logging statements; Starlette debug setting; new exception handler |
| R-06 | Compromised CI identity deploys attacker-controlled code and inherits runtime SA credentials | T-06 | Critical | WIF `attribute_condition` binding repo + ref; deploy-scoped CI SA; no SA keys; SHA-pinned actions; push-on-main triggers only; admin activity alert | **Medium** | CI/CD (Session 3) | WIF provider attribute change; new GitHub Actions workflow; CI SA role grant |
| R-07 | Compromised base image or dependency executes inside the container with the runtime SA's access | T-07 | High | Distroless base pinned by SHA256 digest; image built once and signed, attested, verified and deployed by digest; cosign keyless with issuer and workflow identity pinned; Binary Authorization requiring a KMS attestation at admission; Artifact Registry CMEK with immutable tags; Bandit, pip-audit, Gitleaks, Checkov and Trivy gates. **Remaining gaps:** dependencies pinned by version not hash, and the OS layer of the image passes Trivy by suppression, see [Security-Exceptions](Security-Exceptions.md) | **Medium** | CI/CD | Base image digest change, which invalidates `.trivyignore`; dependency addition or version bump; Dockerfile change |
| R-08 | DNS compromise in AWS repoints traffic away from GCP, upstream of every GCP control | T-08 | High | AWS MFA, no long-lived Route 53 keys; registrar transfer lock; DNSSEC; GCP certificate state monitoring | **Medium** | AWS account owner | AWS account credential change; registrar transfer; certificate renewal failure alert |
| R-09 | Google-managed certificate fails renewal because DNS records no longer point exclusively at the LB IP | T-08 | Medium | Certificate state monitoring alert; documented requirement that the A record points only at the LB forwarding rule IP | **Medium** | Infra (Session 2) | Any A record change; LB IP change; certificate expiry approaching |
| R-10 | Free-trial budget exhaustion takes the entire project offline, not just the service | T-04 | Medium | `max_instance_count`; billing budget alert; IAP reducing the attacker population to named users | **Medium** | Infra (Session 2) | Billing alert fires; `max_instance_count` raised; new billable resource added |

## Reading the register

**Inherent** is the risk before any project-owned control. Google platform properties (GFE TLS termination, DDoS absorption, container runtime isolation) are already factored in because they are not ours to lose.

**Residual** is the risk after controls that **actually exist**. An earlier revision of this register scored rows against controls that had been designed but not built, which flattered R-02 in particular. Rows now say plainly where a control is absent.

- R-01: IAP-direct plus invoker IAM restricted to IAP's service agent. O-1 (cross-project LB admission) is resolved, since the invoker restriction closes it regardless of which LB fronts the service
- R-02: **raised Low to Medium.** The app-side JWT verification this row was scored against does not exist. Only the platform layer holds, so the "fails silently if IAP is removed" scenario is unmitigated: disable IAP and grant `allUsers` invoker and the application serves everyone without complaint
- R-03: output escaping is the fix and is applied. CSP and the size cap are not, and the Cloud Armor layer that was to sit behind them is not deployed at all
- R-04/R-10: IAP narrows the attacker set to one named user, but rate limiting is gone entirely, so a legitimate user faces no throttle above `max_instance_count`
- R-06: WIF conditions are correct but the repository is single-author with no enforced code review
- R-07: **improved.** Digest pinning and admission control, both open gaps when this was written, are now closed. It stays Medium on dependency hash pinning and the suppressed OS CVEs
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
