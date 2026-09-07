# Owned by terraform/bootstrap, which is applied once and never destroyed.

data "google_kms_key_ring" "main" {
  project  = var.project_id
  name     = var.key_ring_name
  location = var.region
}

data "google_kms_crypto_key" "main" {
  name     = "aegis-key"
  key_ring = data.google_kms_key_ring.main.id
}

data "google_kms_crypto_key" "attestor" {
  name     = "aegis-attestor"
  key_ring = data.google_kms_key_ring.main.id
}

data "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.wif_pool_id
}
