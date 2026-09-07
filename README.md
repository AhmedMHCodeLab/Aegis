# Aegis

<p align="center">
  <img src="app/images/AegisLogo.jpg" alt="Aegis" width="140" height="140" style="border-radius: 12px;">
</p>

<p align="center"><strong>Compliance Checkpoint Service for GCP Cloud Run</strong></p>

Aegis evaluates a submitted Cloud Run service configuration against a version-controlled 13-control security baseline. It returns a structured verdict for each control, the evidence used, a score, and remediation guidance.

Aegis is a stateless assessment service. It does not inspect a live GCP project, make outbound calls on behalf of the caller, or persist submitted configurations.

## Production status

**Applied and documented as live in the `aegis-prod-0926` GCP project, region `me-central1`, behind IAP and a global external Application Load Balancer.** The repository contains Terraform, CI/CD configuration, test coverage, and deployment records supporting that statement.

This repository does not establish full production operations maturity. In particular, Cloud Armor is not deployed, application-side IAP JWT verification is not implemented, and the repository does not provide an automated rollback procedure or comprehensive service-level monitoring. Those limitations are stated in [Security-Exceptions.md](Docs/Security-Exceptions.md) and [Risk-Register.md](Docs/Risk-Register.md).

## Solution overview

### Problem

Cloud Run configuration is easy to change and difficult to review consistently. A missing ingress restriction, overprivileged IAM binding, unmanaged secret, weak encryption configuration, or unrestricted egress can be missed when review depends on manual inspection.

### Objective

Provide a deterministic compliance checkpoint that can be used by an analyst, a web UI, a CI pipeline, or another service before a Cloud Run configuration is accepted.

### Input and processing

The caller submits a JSON document containing a resource type and configuration. FastAPI and Pydantic validate the request shape. The evaluation engine loads the version-controlled YAML rule catalogue, resolves fields including nested paths, evaluates assertions, and dispatches selected controls to custom handlers.

### Output

The service returns 13 PASS or FAIL results. Each result includes the control identity, severity, actual value, expected value, and remediation. Missing evidence fails a control where the rule requires presence. The service does not return WARN results today, although the response contract retains a `warn` field.

### Operational boundary

Aegis evaluates the document it receives. It does not discover resources, query GCP APIs, mutate infrastructure, or prove that the submitted document matches a deployed resource. The caller remains responsible for obtaining and authenticating the configuration being assessed.

## Capabilities

### Configuration assurance

- 13 controls across Cloud Run, IAM, KMS, Secret Manager, and Network.
- Declarative YAML rules for ordinary comparisons and custom Python handlers for controls requiring more complex logic.
- Fail-closed handling for absent fields and malformed comparison values.
- Evidence and remediation in every result, including failed controls.
- A stable rule catalogue available through `GET /v1/rules`.

### Service delivery

- Browser UI for submitting a configuration and reviewing results.
- JSON API for automation.
- Stateless execution with no database, cache, or application-managed session store.
- Metadata-only structured JSON logs for completed assessments.
- Optional HMAC-SHA256 signing of assessment responses when `AEGIS_SIGNING_KEY` is configured.

### Platform controls

- Cloud Run with a dedicated runtime service account and second-generation execution environment.
- IAP enabled directly on Cloud Run, with access granted to the configured analyst identity.
- Global load balancer, managed certificate, custom domain path, and TLS 1.2 minimum policy.
- Direct VPC egress through a dedicated subnet, default-deny egress, and Private Google Access routing to restricted Google API addresses.
- Customer-managed encryption for Cloud Run revisions, Artifact Registry, and the response signing secret.
- GitHub Actions authentication through Workload Identity Federation, with no service account key in the repository.
- Binary Authorization admission requiring a KMS-backed attestation for normal images.

The controls above describe what is configured in Terraform and the delivery pipeline. They are not a substitute for independent verification of the deployed project.

## Architecture

```text
  +-------------------------------+
  | AWS account                   |
  | Route 53 public hosted zone   |
  | A record -> GCP LB address    |
  +---------------+---------------+
                  |
                  | TB-6: DNS and certificate validation
                  v
  +---------------------------------------------------------+
  | Google Front End                                         |
  | Global external Application Load Balancer                |
  | Google-managed certificate, TLS 1.2 minimum              |
  | Cloud Armor: not deployed, no WAF or rate limiting       |
  +-------------------------------+-------------------------+
                                  |
                                  | TB-1: public edge
                                  v
  +---------------------------------------------------------+
  | Identity-Aware Proxy                                     |
  | Google sign-in                                           |
  | roles/iap.httpsResourceAccessor for authorised analysts  |
  +-------------------------------+-------------------------+
                                  |
                                  | TB-2: unauthenticated -> authenticated
                                  | IAP service agent invokes Cloud Run
                                  v
  +---------------------------------------------------------+
  | Cloud Run: aegis                                         |
  | IAP enabled directly on the service                      |
  | Only IAP service agent has roles/run.invoker             |
  | Dedicated aegis-run identity, distroless, uid 65532      |
  | Stateless FastAPI application                            |
  +-------------+-------------------+-----------------------+
                |                   |
                | TB-4: runtime     | TB-7: response data
                | identity          | rendered in browser DOM
                v                   +---------------------> Analyst
  +---------------------------+
  | VPC subnet                |
  | Direct VPC egress         |
  | Default-deny firewall     |
  | Private DNS for APIs      |
  +------+------+------+-----+
         |      |      |
         v      v      v
  +---------+ +------+ +----------------------+
  | Secret  | | KMS  | | Cloud Logging and    |
  | Manager | | CMEK | | Monitoring           |
  +---------+ +------+ | audit and IAM alert |
                      +----------------------+

  +-------------------------------+
  | GitHub Actions                 |
  | OIDC token                     |
  +---------------+---------------+
                  |
                  | TB-5: external CI identity
                  v
  +-------------------------------+       +----------------------+
  | Workload Identity Federation  |------>| aegis-ci             |
  | repository and main ref bound  |       | short-lived access   |
  +-------------------------------+       +----------+-----------+
                                                     |
                                                     v
  +---------------------------------------------------------+
  | Build once -> scan -> Artifact Registry by digest       |
  | -> keyless sign and provenance -> verify                |
  | -> KMS attestation -> Binary Authorization -> deploy    |
  +---------------------------------------------------------+
```

The diagram separates the main trust boundaries. Client traffic crosses the AWS DNS boundary, public Google edge, IAP authentication boundary, and Cloud Run workload boundary. Deployment traffic crosses a separate GitHub OIDC and Workload Identity Federation boundary before it can publish or deploy an artifact.

### Request flow and trust boundaries

1. An analyst reaches the custom domain or Cloud Run URL.
2. IAP authenticates the analyst. The configured identity must hold `roles/iap.httpsResourceAccessor`.
3. Only the IAP service agent holds `roles/run.invoker` on the Cloud Run service.
4. The container receives the request and evaluates the submitted document locally.
5. The response is returned as JSON or rendered by the browser UI. Assessment metadata is logged, but the submitted configuration is not intentionally logged.
6. Runtime access to the signing secret and Google services uses the dedicated Cloud Run identity and VPC path.

The application does not verify the IAP signed assertion. Authorization is therefore enforced by IAP and Cloud Run IAM, with no application-side second-line verification. This is an accepted residual risk, not an implemented control. See [Edge-vs-App-Layer-Auth.md](Docs/Edge-vs-App-Layer-Auth.md).

DNS is managed outside this repository in AWS Route 53. The DNS account and registrar are therefore a separate trust boundary upstream of the GCP controls.

## Security model

| Concern | Implemented control | Evidence and limitation |
|---|---|---|
| Ingress and authentication | IAP enabled on Cloud Run; access binding for the authorised identity; IAP service agent is the only invoker | Terraform and the IAP verification notes. Application-side JWT verification is absent. |
| Authorization | Cloud Run IAM prevents callers other than IAP from invoking the service | The service has no application user model or per-user authorization. |
| Runtime identity | Dedicated `aegis-run` service account | Defined in the IAM and Cloud Run modules. |
| Secrets | Signing key stored in Secret Manager and injected by secret reference | The service account has secret accessor permission. Secret rotation procedure is not documented. |
| Encryption | CMEK for revisions, Artifact Registry, and signing secret; keys are in a non-destroyable bootstrap layer | Terraform configuration. Key lifecycle and recovery remain operational responsibilities. |
| Network egress | Direct VPC egress, default-deny firewall, restricted Google API range, private DNS | Terraform configuration and [Direct-VPC-Egress.md](Docs/Direct-VPC-Egress.md). |
| Artifact integrity | SHA-pinned build inputs, Trivy scan, keyless cosign signature, provenance attestation, KMS attestation, Binary Authorization | The CI workflow and Binary Authorization module. OS findings are materially suppressed in `.trivyignore`. |
| Edge protection | Global load balancer, managed certificate, TLS 1.2 minimum | Cloud Armor is not deployed because project quotas are zero and the increase request was denied. There is no WAF or rate limiting. |
| Data handling | No database or application persistence; metadata-only completion logs | Client configuration exists in request memory and the browser DOM for the request lifecycle. |

Preventative controls include IAP, IAM, VPC firewall rules, CMEK, immutable artifact references, and Binary Authorization. Detective controls include Cloud Audit Logs, the IAM policy-change metric and alert, pipeline verification, and test gates. The repository does not demonstrate complete uptime, certificate-renewal, budget, or application-error alert coverage.

## Evaluation model

Rules are loaded from [app/src/rules/](app/src/rules/) when the application starts. Each rule contains control metadata and either a declarative assertion or a custom handler.

The evaluation path is:

```text
request schema
  -> rule catalogue
  -> field resolution
  -> assertion or custom handler
  -> evidence
  -> PASS or FAIL result
  -> summary and remediation
```

### Policy definition

The baseline contains 13 controls:

| Category | Coverage |
|---|---|
| Cloud Run | Ingress, dedicated service account, authentication, TLS minimum version |
| IAM | Overprivileged roles, public bindings, Workload Identity Federation |
| KMS | Customer-managed key, key rotation |
| Secret Manager | Secret storage and workload identity access |
| Network | VPC egress path and restricted egress |

### Fail-closed behaviour

An absent field does not count as compliance. Rules that use negative comparisons first assert that the field exists. IAM and network custom handlers also distinguish an absent section from a declared empty collection where that distinction affects the control. An unparseable numeric value fails its control instead of producing a server error.

### Evidence and custom handlers

The generic engine resolves nested fields such as `encryption.kms_key`, evaluates supported operators, and reports the first failed assertion. Custom handlers are used for IAM binding analysis and for the network control, which accepts either direct VPC egress or a Serverless VPC Access connector because the control is about the security outcome rather than one product mechanism.

## API

### `POST /v1/check`

Evaluates a Cloud Run service configuration. The API accepts the document supplied by the caller; it does not validate that every possible Cloud Run field is present.

```json
{
  "resource_type": "cloud_run_service",
  "config": {
    "ingress": "internal-and-cloud-load-balancing",
    "service_account": "aegis-run@project.iam.gserviceaccount.com",
    "authentication": {"require_auth": true},
    "tls_min_version": "1.3",
    "iam_bindings": [],
    "wif": {"provider": "projects/123/.../repo", "static_keys": []},
    "encryption": {"kms_key": "projects/.../cryptoKeys/main", "key_rotation_period": "7776000s"},
    "secrets": {"storage": "secret_manager", "access_method": "workload_identity"},
    "network": {"vpc_connector": "projects/.../connectors/main", "egress_setting": "private-ranges-only"}
  }
}
```

```json
{
  "summary": {"total": 13, "pass": 13, "fail": 0, "warn": 0, "score": "100%"},
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

When `AEGIS_SIGNING_KEY` is configured, the service returns an `X-Aegis-Signature` header containing an HMAC-SHA256 over the exact compact, sorted JSON response bytes. This provides integrity for the response in transit between the service and a verifier that already knows the shared secret. It is not a user authentication mechanism.

### `GET /v1/rules`

Returns the 13-control catalogue with IDs, categories, names, severities, and descriptions.

### `GET /health`

Returns process health and the number of rules loaded:

```json
{"status": "healthy", "rules_loaded": 13}
```

The endpoint is a liveness-style application check. It does not verify access to Secret Manager, KMS, Artifact Registry, DNS, or the load balancer.

## Production infrastructure

Terraform owns the GCP resources. The bootstrap root is applied once and owns API enablement, the reserved load balancer address, CMEK keys, the Binary Authorization signing key, and the Workload Identity Federation pool and provider. The main root owns the network, IAM bindings, security integrations, Artifact Registry, Cloud Run, load balancer, DNS resources within GCP, and monitoring.

The bootstrap state is intentionally separate. KMS key rings and keys cannot be cleanly destroyed and Workload Identity pools retain deleted identifiers, so the main stack can be rebuilt without destroying the permanent trust anchors. See [Bootstrap-Layer.md](Docs/Bootstrap-Layer.md) and [Deployment.md](Docs/Deployment.md).

The runtime uses direct VPC egress rather than a Serverless VPC Access connector. This avoids a standing connector cost for a service that only needs Google APIs through Private Google Access. It makes subnet sizing and address capacity an operational constraint because Cloud Run instances consume addresses from the subnet.

## Delivery pipeline

```text
pull request
  -> unit and API tests
  -> Bandit, pip-audit, Gitleaks, Checkov
  -> build and Trivy scan, without push

push to main
  -> the same validation gates
  -> build once
  -> Trivy scan
  -> push and capture immutable digest
  -> keyless cosign signature and provenance
  -> verify signature and workflow identity
  -> create KMS Binary Authorization attestation
  -> deploy the same digest to Cloud Run
  -> wait for deployment and print the service URL
```

The pipeline uses GitHub OIDC and GCP Workload Identity Federation. No long-lived service account key is required. Actions are pinned to commit SHAs. The WIF condition restricts the trusted repository owner and `refs/heads/main`.

Keyless cosign and KMS attestation answer different questions. The cosign signature provides publicly verifiable workflow provenance. The KMS attestation is the stable-key proof that Binary Authorization can enforce at Cloud Run admission. Binary Authorization blocks normal images without the required attestation. The bootstrap placeholder image is allowlisted so the service can be created before the first image exists; that is a documented, narrow exception.

Infrastructure changes are separate from application deployment. `terraform.yml` is manual dispatch only. Plan, apply, and destroy are separate choices; apply and destroy require the `production-infra` environment approval, and destroy additionally requires typed confirmation.

## Operations

### Normal operation

The service scales from zero to the configured maximum instance count. It has a 512 MiB memory limit, one vCPU, startup CPU boost, request concurrency of 80, and a configured minimum of zero instances. The application writes structured JSON logs to stdout. Assessment logs contain the resource type and result counts, not the submitted configuration by design.

### Health and monitoring

Terraform enables Cloud Audit Logs for Cloud Run, Secret Manager, and Cloud KMS. It creates a log-based metric and email alert for IAM policy changes.

The repository does not show implemented alerts for uptime, application error rate, certificate renewal, budget exhaustion, or Cloud Run saturation. Cloud Armor rate limiting is also absent. These are operational gaps, not implied capabilities.

### Application changes

Merge to `main` triggers the CI/CD workflow. A successful run deploys a new revision by digest and Binary Authorization evaluates the image. The repository does not define an automated rollback job or a documented revision rollback runbook. Cloud Run revision rollback remains a platform operation that must be performed and verified by an authorised operator.

### Infrastructure changes

Use the deployment procedure in [Deployment.md](Docs/Deployment.md). The first bootstrap and first main apply have manual prerequisites, including the GCS state bucket, initial API enablement where required, IAP OAuth configuration, GitHub Environment configuration, repository variables, and the external DNS A record.

### Secret and key lifecycle

The signing key is generated by Terraform and stored in Secret Manager under CMEK. The runtime receives the secret by reference. Key rings and keys carry `prevent_destroy`; changing or destroying them has consequences for encrypted artifacts and existing attestations. A routine secret rotation runbook is not included in the repository and should be established before ownership transfers.

### Failure handling

The application fails individual controls closed and returns structured failures for malformed comparison values. Infrastructure failures, IAM changes, missing secrets, DNS errors, certificate renewal failures, quota exhaustion, and admission failures are handled by the relevant GCP service or pipeline and require operator diagnosis. The repository documents these boundaries but does not provide a complete incident response runbook.

## Testing and evidence

The repository documents 92 passing tests. The suite covers:

- field resolution and supported comparison operators;
- conjunctions, short-circuiting, and fail-closed behaviour;
- all 13 controls against secure, insecure, and partial fixtures;
- custom handler dispatch;
- health, rule catalogue, API validation, response shape, evidence, and score calculation;
- regression protection for malformed numeric input and absent fields.

The CI workflow runs the test suite under Python 3.11 and also runs Bandit, pip-audit, Gitleaks, Checkov, and Trivy. The current WSL workspace used for this review did not have `pytest` installed, so the test count was not independently rerun here.

The tests do not prove that the deployed GCP resources match Terraform, that IAP, DNS, TLS, VPC egress, Secret Manager, Cloud KMS, Binary Authorization, or monitoring behave correctly in the live project, or that a rollback succeeds. Those claims require deployment verification and operational exercises.

## Limitations and residual risk

The important remaining limitations are:

- **No Cloud Armor.** Project quotas are zero and the increase request was denied. There is no WAF and no rate limiting. IAP restricts access to named users and Cloud Run has a maximum instance count, but an authorised caller is not throttled.
- **No application-side IAP JWT verification.** The application trusts the platform boundary and cannot detect a future configuration that exposes the container with a different invoker binding. The risk register rates this residual risk Medium.
- **No request body size, depth, or key-count limit.** A large submitted document can consume evaluation and autoscaling resources.
- **No Content Security Policy.** Output escaping is implemented for the identified browser rendering path, but CSP is deferred defence in depth.
- **Trivy OS findings are broadly suppressed.** Application dependency findings are gated, but the distroless operating-system layer has suppressed findings, including documented CRITICAL examples. The image must not be described as vulnerability-free.
- **Three Checkov checks are skipped.** The skips cover VPC Flow Logs, project-level service-account administration, and a GitHub OIDC policy check. The rationale and residual cost are recorded in [Security-Exceptions.md](Docs/Security-Exceptions.md).
- **External DNS dependency.** Route 53, the registrar, and their access controls are outside the GCP Terraform state.
- **Single-operator governance.** The repository is single-author, so branch review and separation-of-duties controls are limited. The infrastructure workflow approval gate is the compensating control for Terraform apply and destroy.
- **No live configuration reconciliation.** A passing submitted document is not proof that the deployed Cloud Run service or its dependencies have that configuration.

See [Threat-Model.md](Docs/Threat-Model.md), [Risk-Register.md](Docs/Risk-Register.md), and [Security-Exceptions.md](Docs/Security-Exceptions.md) for the detailed threat treatment and accepted residual risk.

## Design decisions

- [Fail-Closed Evaluation](Docs/Fail-Closed-Evaluation.md): missing evidence fails a control.
- [Python Policy vs OPA](Docs/PythonPolicy-vs-OPA.md): why the current scope uses a Python engine.
- [Distroless Container](Docs/Distroless-Container.md): image surface and runtime trade-offs.
- [Cloud Run over Functions](Docs/Cloud-Run-over-Functions.md): why the service uses a pre-built container.
- [Direct VPC Egress](Docs/Direct-VPC-Egress.md): why direct egress was selected over a connector.
- [IAP Placement](Docs/IAP-Placement.md): why IAP is enabled directly on Cloud Run while the load balancer remains for the custom domain and TLS policy.
- [Edge vs App Layer Auth](Docs/Edge-vs-App-Layer-Auth.md): the intended application-side verification and its current absence.
- [Artifact Admission](Docs/Artifact-Admission.md): why the image carries both keyless provenance and a KMS admission attestation.
- [Bootstrap Layer](Docs/Bootstrap-Layer.md): why permanent trust anchors have a separate lifecycle.

## Deployment and handover

An engineer taking ownership should read [Deployment.md](Docs/Deployment.md) before changing infrastructure. It covers bootstrap, Terraform state, manual prerequisites, environment variables, rebuilds, Cloud Armor enablement, ongoing changes, and teardown.

The minimum handover checklist is:

1. Confirm ownership of the GCP project, billing account, KMS keys, WIF provider, GitHub repository, GitHub Environment, and AWS DNS account.
2. Confirm the authorised IAP user and the external DNS A record.
3. Verify the deployed Cloud Run service, invoker IAM, runtime service account, secret reference, VPC egress, Binary Authorization policy, and certificate state.
4. Run the API and UI smoke checks with a secure fixture and a deliberately insecure fixture.
5. Establish owners and runbooks for rollback, secret rotation, certificate renewal, budget exhaustion, alert response, and the open security exceptions.

Local development:

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\\Scripts\\activate
pip install -r app/requirements.txt
uvicorn src.main:app --host 0.0.0.0 --port 8080 --app-dir app
```

Container build from the repository root:

```bash
docker build -t aegis -f app/Dockerfile .
docker run -p 8080:8080 aegis
```

Open `http://localhost:8080`, or call the API directly:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/v1/rules
curl -X POST http://localhost:8080/v1/check \
  -H "Content-Type: application/json" \
  -d @tests/fixtures/full_secure.json
```
