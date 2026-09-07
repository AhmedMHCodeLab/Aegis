output "signing_key_secret_id" {
  description = "Secret ID of the HMAC signing key, used for Cloud Run secret mount"
  value       = google_secret_manager_secret.signing_key.secret_id
}
