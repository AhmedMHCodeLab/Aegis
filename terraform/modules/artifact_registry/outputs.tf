output "repository_id" {
  description = "Full resource ID of the Artifact Registry repository"
  value       = google_artifact_registry_repository.main.id
}

output "repository_url" {
  description = "Docker registry URL for pushing and pulling images"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_id}"
}
