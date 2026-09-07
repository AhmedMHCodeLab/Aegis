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

variable "key_ring_name" {
  description = "Name of the KMS key ring"
  type        = string
  default     = "aegis"
}

variable "rotation_period" {
  description = "Key rotation period in seconds. 90 days = 7776000s."
  type        = string
  default     = "7776000s"
}

variable "cloud_run_sa_email" {
  description = "Email of the Cloud Run runtime SA, granted secretAccessor on specific secrets"
  type        = string
}
