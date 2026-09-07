# --- Cloud Run runtime service account ---

resource "google_service_account" "cloud_run" {
  project      = var.project_id
  account_id   = "aegis-run"
  display_name = "Aegis Cloud Run runtime"
  description  = "Runtime identity for the Aegis Cloud Run service"
}

resource "google_kms_crypto_key_iam_member" "cloud_run_kms" {
  crypto_key_id = var.crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = google_service_account.cloud_run.member
}

# --- CI/CD service account ---

resource "google_service_account" "ci" {
  project      = var.project_id
  account_id   = "aegis-ci"
  display_name = "Aegis CI/CD"
  description  = "CI identity for GitHub Actions via WIF. Pushes images and deploys revisions."
}

# CI must be able to deploy Cloud Run revisions that run as the runtime SA.
resource "google_service_account_iam_member" "ci_acts_as_runtime" {
  service_account_id = google_service_account.cloud_run.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.ci.member
}

# --- Workload Identity Federation ---
#
# The pool and provider are owned by terraform/bootstrap; only the binding that
# lets this repository impersonate the CI account lives here.

resource "google_service_account_iam_member" "wif_ci_impersonation" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${var.wif_pool_name}/attribute.repository/${var.github_repo}"
}

# Without this CI fails at "terraform init", before it evaluates any
# configuration, because the GCS backend cannot list the state objects.
resource "google_storage_bucket_iam_member" "ci_state" {
  bucket = var.tfstate_bucket
  role   = "roles/storage.objectAdmin"
  member = google_service_account.ci.member
}

locals {
  ci_project_roles = [
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/compute.securityAdmin",
    "roles/cloudkms.admin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/artifactregistry.admin",
    "roles/run.admin",
    "roles/logging.admin",
    "roles/monitoring.admin",
    "roles/iap.admin",
  ]
}

resource "google_project_iam_member" "ci_terraform" {
  for_each = toset(local.ci_project_roles)
  project  = var.project_id
  role     = each.value
  member   = google_service_account.ci.member
}
