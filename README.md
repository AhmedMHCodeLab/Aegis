# Aegis

<p align="center">
  <img src="app/images/AegisLogo.jpg" alt="Aegis" width="140" height="140" style="border-radius: 12px;">
</p>

<p align="center"><strong>Compliance Checkpoint Service for GCP Cloud Run</strong></p>

Aegis evaluates Cloud Run service configurations against a 13-control security baseline and returns a structured compliance report. Every rule is a declarative YAML file; the baseline is auditable, extensible, and version-controlled without touching the evaluation logic.

## What it does

POST a Cloud Run service configuration. Get back:

- A per-control **PASS / FAIL verdict** with evidence (what was found vs. what was expected)
- A **compliance score** (passed / total)
- **Remediation guidance** for every failing control

No agents, no scanners, no GCP credentials required. Aegis judges the configuration document you hand it.

## The baseline

13 controls across 5 categories:

| Category | Controls | Severities |
|---|---|---|
| **Cloud Run** | Ingress restriction, dedicated service account, authentication, TLS minimum version | CRITICAL, HIGH, MEDIUM |
| **IAM** | No overprivileged roles, no public bindings, Workload Identity Federation | CRITICAL, HIGH |
| **KMS** | Customer-managed encryption keys, key rotation | HIGH, MEDIUM |
| **Secret Manager** | Secrets in Secret Manager (not env vars), accessed via WIF | HIGH |
| **Network** | VPC egress path configured, restricted egress | HIGH, MEDIUM |

Rules live in [`app/src/rules/`](app/src/rules/). Complex checks use a custom handler escape hatch while returning the same result contract: three analyse IAM bindings, and one accepts either mechanism that routes Cloud Run egress into a VPC, since the control is about the outcome rather than the product.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Client (UI / curl / CI pipeline)                   │
│  POST /v1/check  { resource_type, config }          │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────┐
│  FastAPI                                             │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ Pydantic │→ │ Engine       │→ │ YAML Rules    │  │
│  │ validate │  │ resolve_field│  │ 13 controls   │  │
│  │          │  │ OPERATORS    │  │ 5 categories  │  │
│  │          │  │ assertions   │  │ 4 custom      │  │
│  └──────────┘  └──────────────┘  └───────────────┘  │
│                       │                              │
│                       ▼                              │
│  { summary, results[] }  → JSON + structured log    │
└──────────────────────────────────────────────────────┘
```

**Stack:** Python 3.11, FastAPI, Pydantic, PyYAML, Jinja2
**Container:** Distroless Python (`gcr.io/distroless/python3-debian12:nonroot`, uid 65532)
**Zero runtime dependencies:** no database, no OPA, no cloud credentials.

## Quick start

```bash
# Build from repository root
docker build -t aegis -f app/Dockerfile .

# Run (nonroot, port 8080)
docker run -p 8080:8080 aegis
```

Open [http://localhost:8080](http://localhost:8080) for the UI, or use the API directly:

```bash
# Health check
curl http://localhost:8080/health

# List the baseline
curl http://localhost:8080/v1/rules

# Evaluate a configuration
curl -X POST http://localhost:8080/v1/check \
  -H "Content-Type: application/json" \
  -d @tests/fixtures/full_secure.json
```

### Without Docker

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r app/requirements.txt
uvicorn src.main:app --host 0.0.0.0 --port 8080 --app-dir app
```

## API

### `POST /v1/check`

Evaluate a Cloud Run service configuration.

```json
{
  "resource_type": "cloud_run_service",
  "config": {
    "ingress": "internal-and-cloud-load-balancing",
    "service_account": "my-sa@project.iam.gserviceaccount.com",
    "authentication": { "require_auth": true },
    "tls_min_version": "1.3",
    "iam_bindings": [],
    "wif": { "provider": "projects/123/.../repo", "static_keys": [] },
    "encryption": { "kms_key": "projects/.../cryptoKeys/main", "key_rotation_period": "7776000s" },
    "secrets": { "storage": "secret_manager", "access_method": "workload_identity" },
    "network": { "vpc_connector": "projects/.../connectors/main", "egress_setting": "private-ranges-only" }
  }
}
```

**Response:**

```json
{
  "summary": { "total": 13, "pass": 13, "fail": 0, "warn": 0, "score": "100%" },
  "results": [
    {
      "rule_id": "CR-001",
      "category": "Cloud Run",
      "name": "Internal ingress only",
      "status": "PASS",
      "severity": "CRITICAL",
      "evidence": {
        "field": "ingress",
        "actual": "internal-and-cloud-load-balancing",
        "expected": "internal-and-cloud-load-balancing"
      },
      "remediation": "Set ingress to internal-and-cloud-load-balancing."
    }
  ]
}
```

When `AEGIS_SIGNING_KEY` is set, the response carries an `X-Aegis-Signature` header holding an HMAC-SHA256 over the exact bytes returned. Keys are sorted and separators compact, so a caller can recompute the digest and confirm a verdict came from this service unaltered. In deployment the key is generated by Terraform and read from Secret Manager; the application never sees a literal.

### `GET /v1/rules`

Returns the full 13-control catalogue with IDs, names, categories, severities, and descriptions.

### `GET /health`

```json
{ "status": "healthy", "rules_loaded": 13 }
```

## Infrastructure

Every GCP resource is Terraform-managed. The console is for inspection, not provisioning.

```
                        Internet
                            │
                            ▼
            ┌───────────────────────────────────┐
            │  Global external load balancer    │
            │  Cloud Armor: rate limiting¹       │
            │  Managed cert, TLS 1.2 RESTRICTED │
            └─────────────────┬─────────────────┘
                              ▼
            ┌───────────────────────────────────┐
            │  IAP — on the service itself      │
            └─────────────────┬─────────────────┘
                              ▼
            ┌───────────────────────────────────┐
            │  Cloud Run  (aegis-run identity)  │
            │  CMEK revisions, gen2 sandbox     │
            │  signing key by secret reference  │
            └─────────────────┬─────────────────┘
                              │ direct VPC egress
                              ▼
            ┌───────────────────────────────────┐
            │  VPC — egress denied by default   │
            │  one pinhole: 199.36.153.4/30     │
            │  private DNS → restricted.*       │
            └───────────────────────────────────┘
```

Egress is denied by default with a single pinhole to `restricted.googleapis.com`, and private DNS zones override the Google API hostnames so Private Google Access resolves inside the VPC. Without those zones the names resolve to public addresses the deny rule blocks, and the service cannot reach its own registry: the three parts only work as a set. IAP sits on the Cloud Run service rather than the load balancer, so authentication holds even for a request that reaches the service directly.

Data at rest is encrypted with a customer-managed key, including the container images and the response signing key. Key rings carry `prevent_destroy`, because destroying a key orphans everything encrypted under it.

¹ Cloud Armor is gated behind `enable_cloud_armor`. The project's `SECURITY_POLICY_RULES` quota is zero, a residual restriction from the billing account's free trial origin that persists after upgrade to Paid. When the quota is granted, the policy adds preconfigured SQLi and XSS signatures alongside rate limiting.

Reasoning in [IAP-Placement.md](Docs/IAP-Placement.md) and [Direct-VPC-Egress.md](Docs/Direct-VPC-Egress.md).

## Pipeline

```
pull request ──┬── tests
               ├── Bandit         SAST
               ├── pip-audit      SCA
               ├── Gitleaks       secrets
               ├── Checkov        IaC
               └── build + Trivy  (not pushed)

push to main ──┬── the same five gates
               └── build once
                    └── Trivy
                         └── push ──────────► digest
                              └── cosign sign          by digest
                                   └── attest SLSA     by digest
                                        └── verify     by digest
                                             └── KMS attestation
                                                  └── deploy
                                                       └── Binary Authorization
                                                           admits, or blocks
```

The image is built **once** and every downstream step addresses it by digest, so the artifact Cloud Run receives is provably the artifact Trivy scanned rather than a second build of the same source. Signing is keyless: cosign exchanges the workflow's OIDC token through Sigstore, and verification pins the issuer and the exact workflow identity, so the signature proves *which repository and workflow* produced the image, not merely that someone signed it. GCP authentication uses Workload Identity Federation, leaving no service account key to leak, and every action is pinned to a commit SHA because tags are mutable, as the March 2026 `trivy-action` compromise demonstrated.

None of that protects the **platform**, only the pipeline: `cosign verify` constrains what this workflow deploys and says nothing about someone with `roles/run.developer` deploying by hand. Binary Authorization closes that at the admission layer. It cannot read a keyless signature, since a policy matches a stable public key and keyless has none by design, so the image carries two proofs: the keyless signature is the public claim, verifiable by anyone with no GCP access, and a KMS-signed attestation is the enforceable one. See [Artifact-Admission.md](Docs/Artifact-Admission.md) for the alternatives weighed and what the documentation could not settle.

Infrastructure changes never ride along with an application push. `terraform.yml` is `workflow_dispatch` only, offering `plan`, `apply` and `destroy` as explicit choices, with apply and destroy behind a GitHub Environment that requires approval and destroy additionally requiring a typed confirmation.

Module inventory, bootstrap sequence and the handful of steps that cannot be Terraform are in [Deployment.md](Docs/Deployment.md).

## Fail-closed semantics

A configuration that says nothing about a control fails it. Silence is not compliance.

This is enforced at the rule layer via assertion conjunctions, not an engine override, so the rules remain the single source of truth. A lint test guards against regression. Full rationale in [Fail-Closed-Evaluation.md](Docs/Fail-Closed-Evaluation.md).

## Tests

```bash
pytest -v
```

92 tests: engine operators, field resolution, assertion conjunctions, all 13 rules against secure, insecure and partial fixtures, the API contract, and a data lint that prevents reintroduction of the fail-open bug.

## Design decisions

Application:

- [**Fail-Closed Evaluation**](Docs/Fail-Closed-Evaluation.md) -> Why absent fields fail controls, and why the engine-level alternative was rejected
- [**Python Policy vs OPA**](Docs/PythonPolicy-vs-OPA.md) -> Why a Python engine over Open Policy Agent for this scope
- [**Distroless Container**](Docs/Distroless-Container.md) -> Why distroless over slim/alpine, and what it removes from the attack surface

Infrastructure:

- [**Cloud Run over Functions**](Docs/Cloud-Run-over-Functions.md) -> Why a pre-built image, and which of the assumed differentiators no longer hold
- [**Direct VPC Egress**](Docs/Direct-VPC-Egress.md) -> Why a network interface on the subnet instead of a Serverless VPC Access connector
- [**IAP Placement**](Docs/IAP-Placement.md) -> Why IAP moved from the backend service onto Cloud Run, reversing the original decision
- [**Edge vs App Layer Auth**](Docs/Edge-vs-App-Layer-Auth.md) -> Where the authorisation boundary sits and what the application is still responsible for
- [**Artifact Admission**](Docs/Artifact-Admission.md) -> Why the image carries two signatures, and why Binary Authorization cannot read the keyless one

Security posture:

- [**Threat Model**](Docs/Threat-Model.md) -> STRIDE per trust boundary across the service, its edge, its identities and its build path
- [**Risk Register**](Docs/Risk-Register.md) -> Each threat scored, with the control that addresses it or the residual risk accepted
- [**Spec Deviations**](Docs/Spec-Deviations.md) -> Every departure from the original specification, with justification