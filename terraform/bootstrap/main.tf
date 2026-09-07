resource "google_compute_global_address" "lb" {
  project = var.project_id
  name    = var.lb_address_name

  lifecycle {
    prevent_destroy = true
  }
}

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

resource "google_kms_crypto_key" "attestor" {
  name     = "aegis-attestor"
  key_ring = google_kms_key_ring.main.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm = "EC_SIGN_P256_SHA256"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.wif_pool_id
  display_name              = "GitHub Actions"
  description               = "OIDC identity pool for GitHub Actions CI/CD"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.wif_provider_id
  display_name                       = "Aegis GitHub repo"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.actor"               = "assertion.actor"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
  }

  attribute_condition = "assertion.repository_owner_id == \"${var.github_owner_id}\" && assertion.ref == \"refs/heads/main\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  lifecycle {
    prevent_destroy = true
  }
}
