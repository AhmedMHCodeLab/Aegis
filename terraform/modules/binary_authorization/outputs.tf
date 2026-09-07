output "attestor_name" {
  description = "Short name of the attestor, used by gcloud container binauthz in CI"
  value       = google_binary_authorization_attestor.main.name
}

output "attestor_key_version" {
  description = "KMS key version resource ID used to sign attestations in CI"
  value       = data.google_kms_crypto_key_version.attestor.id
}
