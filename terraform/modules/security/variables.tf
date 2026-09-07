variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "project_number" {
  description = "GCP project number, used to construct service agent emails"
  type        = string
}

variable "region" {
  description = "GCP region, must match Artifact Registry and Secret Manager locations"
  type        = string
}

variable "crypto_key_id" {
  description = "ID of the CMEK key, created by terraform/bootstrap"
  type        = string
}

variable "cloud_run_sa_email" {
  description = "Email of the Cloud Run runtime SA, granted secretAccessor on specific secrets"
  type        = string
}
