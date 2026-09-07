output "service_url" {
  description = "Public URL of the service, behind the load balancer and IAP"
  value       = module.dns.lb_url
}

output "lb_ip_address" {
  description = "Load balancer IP. The domain's A record points here."
  value       = module.dns.lb_ip_address
}

output "cloud_run_url" {
  description = "Cloud Run URL, bypassing the load balancer. Still behind IAP."
  value       = module.cloud_run.service_uri
}

output "artifact_registry_repository" {
  description = "Docker repository images are pushed to"
  value       = module.artifact_registry.repository_url
}

output "cloud_run_sa_email" {
  description = "Runtime service account the Cloud Run service runs as"
  value       = module.iam.cloud_run_sa_email
}

output "ci_sa_email" {
  description = "Service account GitHub Actions impersonates through WIF"
  value       = module.iam.ci_sa_email
}
