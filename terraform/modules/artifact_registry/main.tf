resource "google_artifact_registry_repository" "main" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  kms_key_name  = var.kms_key_id

  docker_config {
    immutable_tags = true
  }
}

resource "google_artifact_registry_repository_iam_member" "ci_writer" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.main.repository_id
  role       = "roles/artifactregistry.writer"
  member     = var.ci_sa_member
}
