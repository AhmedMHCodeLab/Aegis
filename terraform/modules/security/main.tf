# --- KMS ---

resource "google_kms_key_ring" "main" {
  project  = var.project_id
  name     = var.key_ring_name
  location = var.region

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "main" {
  name            = "aegis-key"
  key_ring        = google_kms_key_ring.main.id
  rotation_period = var.rotation_period
  purpose         = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = true
  }
}

# Artifact Registry service agent: grant CMEK access
resource "google_project_service_identity" "artifact_registry" {
  provider = google-beta
  project  = var.project_id
  service  = "artifactregistry.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "artifact_registry" {
  crypto_key_id = google_kms_crypto_key.main.id
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
  crypto_key_id = google_kms_crypto_key.main.id
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
  crypto_key_id = google_kms_crypto_key.main.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secret_manager.email}"
}

# --- Signing Key Secret ---

resource "random_bytes" "signing_key" {
  length = 32
}

resource "google_secret_manager_secret" "signing_key" {
  project   = var.project_id
  secret_id = "aegis-signing-key"

  replication {
    user_managed {
      replicas {
        location = var.region
        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.main.id
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
