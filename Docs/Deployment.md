# Deployment

Operational reference for standing up Aegis. The README covers what the system is;
this covers what it takes to run it.

## Terraform modules

| Module | Provisions |
|---|---|
| `bootstrap` (separate root) | KMS key ring, CMEK key, attestor signing key, WIF pool and OIDC provider. Applied once, never destroyed. |
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

**The `terraform/bootstrap` layer.** It owns the KMS key ring, both crypto keys and
the Workload Identity pool and provider: five resources GCP will not let Terraform
destroy and recreate. Applied once, then left alone. Reasoning in
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

API enablement is not managed in Terraform. Alongside the usual set, Binary
Authorization needs:

- `binaryauthorization.googleapis.com`
- `containeranalysis.googleapis.com`

## Manual configuration

| Step | Why it is not Terraform |
|---|---|
| OAuth consent screen, under **APIs & Services** | IAP auto-provisions its OAuth client only for projects inside an organisation. A standalone project needs the consent screen configured once, before IAP will authenticate anyone. |
| GitHub Environment `production-infra`, with required reviewers | The approval gate for `terraform apply` and `destroy`. Without it both run unattended. |
| Repository variables `TF_PROJECT_ID`, `TF_PROJECT_NUMBER`, `TF_REGION`, `TF_IAP_USER_EMAIL`, `TF_GITHUB_OWNER_ID` | Terraform reads them as `TF_VAR_*`, so environment tfvars stay local and out of git. |
| `A` record for the service domain, pointing at the load balancer address | A Google-managed certificate only validates once the name resolves to the balancer. |

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
