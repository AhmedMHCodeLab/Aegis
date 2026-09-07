# Deployment

Operational reference for standing up Aegis. The README covers what the system is;
this covers what it takes to run it.

## Terraform modules

| Module | Provisions |
|---|---|
| `bootstrap` (separate root) | API enablement, KMS key ring, CMEK key, attestor signing key, WIF pool and OIDC provider, reserved load balancer address. Applied once, never destroyed. |
| `networking` | VPC, regional subnet, default-deny egress, private DNS zones for `googleapis.com`, `pkg.dev`, `gcr.io` |
| `security` | CMEK grants to service agents, HMAC signing key in Secret Manager |
| `iam` | `aegis-run` and `aegis-ci` service accounts, WIF impersonation binding, CI project roles |
| `artifact_registry` | Docker repository, CMEK encrypted, immutable tags |
| `binary_authorization` | Container Analysis note, attestor, admission policy requiring attestation |
| `cloud_run` | Service with IAP, direct VPC egress, CMEK revisions, secret reference |
| `dns` | Global load balancer, serverless NEG, Cloud Armor (gated on quota), managed certificate, TLS policy |
| `monitoring` | Data access audit logs, IAM change metric and alert |

## Bootstrap

Three things cannot come from a routine apply.

**The state bucket.** Terraform cannot hold its own backend in the state it is about
to write.

```bash
gcloud storage buckets create gs://aegis-prod-0926-tfstate \
  --location=me-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://aegis-prod-0926-tfstate --versioning
```

**The `terraform/bootstrap` layer.** It owns everything the main stack needs to
already exist: the sixteen enabled APIs, the KMS key ring and both crypto keys,
the Workload Identity pool and provider, and the reserved load balancer address.
Applied once, then left alone. Reasoning in
[Bootstrap-Layer.md](Bootstrap-Layer.md).

```bash
cd terraform/bootstrap
terraform init
terraform apply \
  -var project_id=aegis-prod-0926 \
  -var region=me-central1 \
  -var github_owner_id=145441921
```

**The first main apply runs locally.** CI authenticates through the Workload Identity
pool, so there is no identity for CI to assume until bootstrap has run.

```bash
cd terraform
terraform init
terraform plan  -var-file=environments/prod/terraform.tfvars
terraform apply -var-file=environments/prod/terraform.tfvars
```

The first apply of the main stack pauses ten minutes on `time_sleep`. Cloud
Monitoring registers a log-based metric descriptor lazily after Logging creates the
metric, and the IAM change alert cannot reference it before then. The wait happens
on create only, not on subsequent applies.

## Rebuilding

The main stack is destroy/apply safe on its own:

```bash
cd terraform
terraform destroy -var-file=environments/prod/terraform.tfvars
terraform apply   -var-file=environments/prod/terraform.tfvars
```

Do not run `terraform destroy` in `terraform/bootstrap`. Every resource there
carries `prevent_destroy`, so it will refuse, which is the intended answer: the key
ring and crypto keys cannot be deleted from GCP at all, and deleting the WIF pool
reserves its ID for thirty days.

Cloud Run is created from a public placeholder image, since Artifact Registry is empty
at that point. The first pipeline run replaces it, and `ignore_changes` on the image
keeps Terraform from reverting the deployed digest afterwards. The placeholder is
allowlisted in the Binary Authorization policy for the same reason: it carries no
attestation and is not ours to attest to.

## Enabled APIs

All sixteen APIs the project needs are managed in `terraform/bootstrap/apis.tf`
and enabled by the bootstrap apply. Nothing to do by hand, with one exception
below.

They carry `disable_on_destroy = false`. Disabling an API breaks everything
already using it, so removing one from Terraform forgets it rather than
switching it off under a running service.

**The exception.** Terraform cannot enable APIs without first being able to call
the API that enables APIs. On a brand new project, enable these two by hand
before the first bootstrap apply:

```bash
gcloud services enable \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=aegis-prod-0926
```

Both are on by default in most projects, in which case this is a no-op.

## Manual configuration

| Step | Why it is not Terraform |
|---|---|
| OAuth consent screen (branding), under **APIs & Services** | Prerequisite for the OAuth client below. Configured once. |
| Custom OAuth client for IAP, at **Security > Identity-Aware Proxy > (service) > Settings > Custom OAuth**. Use the auto-generate option rather than creating a client by hand. | IAP's Google-managed OAuth client authenticates only users inside an organisation, so a standalone project needs a custom one. Google documents that OAuth clients cannot be created programmatically, so this cannot be Terraformed. Without it every request returns "Empty Google Account OAuth client ID(s)/secret(s)" even though DNS, TLS and routing are all correct. Auto-generate creates the client and registers its redirect URI in one step; doing it manually means creating the client, copying a secret that is shown exactly once, then adding a redirect URI that embeds the client's own ID, and is worth avoiding. |
| GitHub Environment `production-infra`, with required reviewers | The approval gate for `terraform apply` and `destroy`. Without it both run unattended. |
| Repository variables `TF_PROJECT_ID`, `TF_PROJECT_NUMBER`, `TF_REGION`, `TF_IAP_USER_EMAIL`, `TF_GITHUB_OWNER_ID` | Terraform reads them as `TF_VAR_*`, so environment tfvars stay local and out of git. |
| `A` record for the service domain, pointing at the load balancer address. Get the address with `cd terraform/bootstrap && terraform output lb_ip_address`. | The domain is registered externally, so there is no Cloud DNS zone for Terraform to write into. A Google-managed certificate stays in `PROVISIONING` and reports `FAILED_NOT_VISIBLE` until the name resolves to the balancer. The address is owned by the bootstrap root, so it survives teardowns and this record is set once rather than after every rebuild. |

## Cloud Armor

`enable_cloud_armor` defaults to `false`, so **no WAF and no rate limiting are
deployed**. The load balancer, managed certificate and TLS policy are unaffected.

The project's Cloud Armor quotas are all zero:

```
SECURITY_POLICIES = 0
SECURITY_POLICY_RULES = 0
SECURITY_POLICY_CEVAL_RULES = 0
```

A quota increase request for the smallest usable value was denied instantly
rather than queued, which indicates an account-level restriction rather than a
sizing decision. The billing account originated as a free trial, and Cloud Armor
quotas are set to zero during a trial and do not lift automatically on upgrade to
paid. Google's automated quota system weighs billing history and account age, so
a recently upgraded account fails it. Escalating requires a Cloud Billing Support
case for manual review; there is no self-service path left.

When quota is granted, set `enable_cloud_armor = true` on the `dns` module. The
policy is already written and adds preconfigured SQLi and XSS signatures plus a
100 request per minute per IP throttle.

## Ongoing changes

Application changes deploy themselves: merge to `main` and the pipeline builds, scans,
signs, attests and deploys.

Infrastructure changes never ride along with an application push. `terraform.yml` is
`workflow_dispatch` only, offering `plan`, `apply` and `destroy` as explicit choices.
Apply and destroy sit behind the `production-infra` environment and wait on approval;
destroy additionally requires typing `DESTROY` as a confirmation input.

## Teardown

`terraform.yml` with `destroy` removes the main stack. It cannot touch
`terraform/bootstrap`, which holds separate state and is not wired into any
workflow.

What survives a teardown is the bootstrap layer: the key ring, the CMEK key, the
attestor signing key, and the WIF pool and provider. That is not a safety
preference, it is what GCP allows. Key rings and crypto keys have no delete API,
and a deleted WIF pool reserves its ID for thirty days. Keeping them in their own
root is what makes the main stack safe to destroy and rebuild at will. See
[Bootstrap-Layer.md](Bootstrap-Layer.md).
