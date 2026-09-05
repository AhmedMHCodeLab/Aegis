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
| **Network** | VPC connector attached, restricted egress | MEDIUM |

Rules live in [`app/src/rules/`](app/src/rules/). Complex checks (IAM binding analysis) use a custom handler escape hatch while returning the same result contract.

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
│  │          │  │ assertions   │  │ 3 custom      │  │
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

### `GET /v1/rules`

Returns the full 13-control catalogue with IDs, names, categories, severities, and descriptions.

### `GET /health`

```json
{ "status": "healthy", "rules_loaded": 13 }
```

## Fail-closed semantics

A configuration that says nothing about a control fails it. Silence is not compliance.

This is enforced at the rule layer via assertion conjunctions, not an engine override, so the rules remain the single source of truth. A lint test guards against regression. Full rationale in [Fail-Closed-Evaluation.md](Docs/Fail-Closed-Evaluation.md).

## Tests

```bash
pytest -v
```

84 tests: engine operators, field resolution, assertion conjunctions, all 13 rules against secure/insecure/partial fixtures, the API contract, and a data lint that prevents reintroduction of the fail-open bug.

## Design decisions

- [**Fail-Closed Evaluation**](Docs/Fail-Closed-Evaluation.md) -> Why absent fields fail controls, and why the engine-level alternative was rejected
- [**Python Policy vs OPA**](Docs/PythonPolicy-vs-OPA.md) -> Why a Python engine over Open Policy Agent for this scope

## Project structure

```
├── app/
│   ├── src/
│   │   ├── engine.py          # Evaluation engine
│   │   ├── main.py            # FastAPI routes + structured logging
│   │   ├── schemas.py         # Pydantic request/response models
│   │   └── rules/
│   │       ├── cloud_run.yaml # CR-001 to CR-004
│   │       ├── iam.yaml       # IAM-001 to IAM-003 (custom handlers)
│   │       ├── kms.yaml       # KMS-001, KMS-002
│   │       ├── secrets.yaml   # SEC-001, SEC-002
│   │       ├── network.yaml   # NET-001, NET-002
│   │       └── custom/        # Handler modules for complex checks
│   ├── templates/
│   │   └── index.html         # Single-page UI (Assess / Results / Rules)
│   ├── static/
│   ├── images/
│   └── Dockerfile
├── tests/
│   ├── fixtures/              # 12 config fixtures
│   ├── test_engine.py
│   ├── test_rules.py
│   └── test_api.py
└── Docs/
```
