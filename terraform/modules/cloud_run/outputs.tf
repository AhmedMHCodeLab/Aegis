output "service_id" {
  description = "Full resource ID of the Cloud Run service"
  value       = google_cloud_run_v2_service.main.id
}

output "service_uri" {
  description = "Primary HTTPS URL of the Cloud Run service (run.app)"
  value       = google_cloud_run_v2_service.main.uri
}

output "service_name" {
  description = "Name of the Cloud Run service, used as LB backend"
  value       = google_cloud_run_v2_service.main.name
}
