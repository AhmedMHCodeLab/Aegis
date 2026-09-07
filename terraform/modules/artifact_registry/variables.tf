variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the repository"
  type        = string
}

variable "repository_id" {
  description = "Name of the Docker repository"
  type        = string
  default     = "aegis"
}

variable "kms_key_id" {
  description = "KMS crypto key ID for CMEK encryption"
  type        = string
}

variable "ci_sa_member" {
  description = "IAM member string for the CI SA, granted roles/artifactregistry.writer"
  type        = string
}
