output "lb_ip_address" {
  description = "Reserved global IP the DNS A record points at"
  value       = google_compute_global_address.lb.address
}

output "key_ring_id" {
  description = "ID of the KMS key ring"
  value       = google_kms_key_ring.main.id
}

output "crypto_key_id" {
  description = "ID of the CMEK key used for encryption at rest"
  value       = google_kms_crypto_key.main.id
}

output "attestor_key_id" {
  description = "ID of the asymmetric signing key backing the Binary Authorization attestor"
  value       = google_kms_crypto_key.attestor.id
}

output "wif_pool_name" {
  description = "Full resource name of the WIF pool, used to build the principalSet binding"
  value       = google_iam_workload_identity_pool.github.name
}

output "wif_provider_name" {
  description = "Full resource name of the WIF provider, used in the GitHub Actions auth step"
  value       = google_iam_workload_identity_pool_provider.github.name
}
