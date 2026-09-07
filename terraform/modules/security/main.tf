# The key ring and crypto key are owned by terraform/bootstrap and arrive here
# as crypto_key_id. Everything below can be freely destroyed and recreated.

# Artifact Registry service agent: grant CMEK access
resource "google_project_service_identity" "artifact_registry" {
  provider = google-beta
  project  = var.project_id
  service  = "artifactregistry.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "artifact_registry" {
  crypto_key_id = var.crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.artifact_registry.email}"
}

# Cloud Run service agent: grant CMEK access for revision encryption
resource "google_project_service_identity" "cloud_run" {
  provider = google-beta
  project  = var.project_id
  service  = "run.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "cloud_run" {
  crypto_key_id = var.crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.cloud_run.email}"
}

# Secret Manager service agent: grant CMEK access
resource "google_project_service_identity" "secret_manager" {
  provider = google-beta
  project  = var.project_id
  service  = "secretmanager.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "secret_manager" {
  crypto_key_id = var.crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secret_manager.email}"
}

# A CMEK grant is not usable the instant it is written. Consumers that encrypt
# with the key must wait for the binding to propagate or they fail with
# "Permission denied on Cloud KMS key".
resource "time_sleep" "cmek_iam_propagation" {
  depends_on = [
    google_kms_crypto_key_iam_member.artifact_registry,
    google_kms_crypto_key_iam_member.cloud_run,
    google_kms_crypto_key_iam_member.secret_manager,
  ]
  create_duration = "60s"
}

# --- Signing Key Secret ---

resource "random_bytes" "signing_key" {
  length = 32
}

resource "google_secret_manager_secret" "signing_key" {
  project    = var.project_id
  secret_id  = "aegis-signing-key"
  depends_on = [time_sleep.cmek_iam_propagation]

  replication {
    user_managed {
      replicas {
        location = var.region
        customer_managed_encryption {
          kms_key_name = var.crypto_key_id
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "signing_key" {
  secret      = google_secret_manager_secret.signing_key.id
  secret_data = random_bytes.signing_key.base64
}

resource "google_secret_manager_secret_iam_member" "cloud_run_accessor" {
  secret_id = google_secret_manager_secret.signing_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.cloud_run_sa_email}"
}
