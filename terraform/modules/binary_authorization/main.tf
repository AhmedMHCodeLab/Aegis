data "google_kms_crypto_key_version" "attestor" {
  crypto_key = var.attestor_key_id
}

resource "google_container_analysis_note" "attestor" {
  project = var.project_id
  name    = "aegis-built-by-ci"

  attestation_authority {
    hint {
      human_readable_name = "Aegis image built and scanned by GitHub Actions"
    }
  }
}

resource "google_binary_authorization_attestor" "main" {
  project = var.project_id
  name    = "aegis-built-by-ci"

  attestation_authority_note {
    note_reference = google_container_analysis_note.attestor.name

    public_keys {
      id = data.google_kms_crypto_key_version.attestor.id

      pkix_public_key {
        public_key_pem      = data.google_kms_crypto_key_version.attestor.public_key[0].pem
        signature_algorithm = data.google_kms_crypto_key_version.attestor.public_key[0].algorithm
      }
    }
  }
}

resource "google_binary_authorization_policy" "main" {
  project = var.project_id


  global_policy_evaluation_mode = "ENABLE"


  admission_whitelist_patterns {
    name_pattern = "us-docker.pkg.dev/cloudrun/container/*"
  }

  default_admission_rule {
    evaluation_mode  = "REQUIRE_ATTESTATION"
    enforcement_mode = "ENFORCED_BLOCK_AND_AUDIT_LOG"

    require_attestations_by = [
      google_binary_authorization_attestor.main.name,
    ]
  }
}

resource "google_kms_crypto_key_iam_member" "ci_signer" {
  crypto_key_id = var.attestor_key_id
  role          = "roles/cloudkms.signerVerifier"
  member        = var.ci_sa_member
}

resource "google_container_analysis_note_iam_member" "ci_attacher" {
  project = var.project_id
  note    = google_container_analysis_note.attestor.name
  role    = "roles/containeranalysis.notes.attacher"
  member  = var.ci_sa_member
}

resource "google_binary_authorization_attestor_iam_member" "ci_viewer" {
  project  = var.project_id
  attestor = google_binary_authorization_attestor.main.name
  role     = "roles/binaryauthorization.attestorsViewer"
  member   = var.ci_sa_member
}
