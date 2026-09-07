# Deployment

Operational reference for standing up Aegis. The README covers what the system is;
this covers what it takes to run it.

## Terraform modules

| Module | Provisions |
|---|---|
| `networking` | VPC, regional subnet, default-deny egress, private DNS zones for `googleapis.com`, `pkg.dev`, `gcr.io` |
| `security` | KMS key ring and rotating key with `prevent_destroy`, CMEK grants to service agents, HMAC signing key in Secret Manager |
| `iam` | `aegis-run` and `aegis-ci` service accounts, Workload Identity Federation pool and OIDC provider |
| `artifact_registry` | Docker repository, CMEK encrypted, immutable tags |
| `binary_authorization` | KMS attestor signing key, Container Analysis note, admission policy requiring attestation |
| `cloud_run` | Service with IAP, direct VPC egress, CMEK revisions, secret reference |
| `dns` | Global load balancer, serverless NEG, Cloud Armor (gated on quota), managed certificate, TLS policy |
| `monitoring` | Data access audit logs, IAM change metric and alert |

## Bootstrap

Two things cannot come from the first apply, for the same underlying reason: they are
what the apply depends on.

**The state bucket.** Terraform cannot hold its own backend in the state it is about
to write.

```bash
gcloud storage buckets create gs://aegis-prod-0926-tfstate \
  --location=me-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://aegis-prod-0926-tfstate --versioning
```

**The first apply itself runs locally.** CI authenticates through a Workload Identity
pool that the first apply is what creates, so there is no identity for CI to assume
until it has run once.

```bash
cd terraform
terraform init
terraform plan  -var-file=environments/prod/terraform.tfvars
terraform apply -var-file=environments/prod/terraform.tfvars
```

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

`terraform.yml` with `destroy` removes the stack, with two deliberate exceptions.
The KMS key ring, the CMEK key and the attestor signing key all carry
`prevent_destroy`: destroying a key orphans everything encrypted under it, and
destroying the attestor key invalidates every attestation and blocks all deployment
until a new key, attestor and attestations exist. Removing them is a conscious act,
not a side effect of a teardown.
