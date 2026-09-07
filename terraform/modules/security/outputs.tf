output "key_ring_id" {
  description = "ID of the KMS key ring"
  value       = google_kms_key_ring.main.id
}

output "crypto_key_id" {
  description = "ID of the KMS crypto key, used as kms_key_name for CMEK"
  value       = google_kms_crypto_key.main.id
}

output "signing_key_secret_id" {
  description = "Secret ID of the HMAC signing key, used for Cloud Run secret mount"
  value       = google_secret_manager_secret.signing_key.secret_id
}
