variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "attestor_key_id" {
  description = "ID of the asymmetric signing key, created by terraform/bootstrap"
  type        = string
}

variable "ci_sa_member" {
  description = "IAM member string for the CI service account that creates attestations"
  type        = string
}
