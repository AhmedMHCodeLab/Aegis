output "cloud_run_sa_email" {
  description = "Email of the Cloud Run runtime service account"
  value       = google_service_account.cloud_run.email
}

output "cloud_run_sa_member" {
  description = "IAM member string for the Cloud Run runtime SA"
  value       = google_service_account.cloud_run.member
}

output "ci_sa_email" {
  description = "Email of the CI/CD service account"
  value       = google_service_account.ci.email
}

output "ci_sa_member" {
  description = "IAM member string for the CI/CD SA"
  value       = google_service_account.ci.member
}

output "ci_sa_name" {
  description = "Full resource name of the CI SA, used for WIF provider binding"
  value       = google_service_account.ci.name
}

output "wif_provider_name" {
  description = "Full resource name of the WIF provider, used in GitHub Actions auth step"
  value       = google_iam_workload_identity_pool_provider.github.name
}
