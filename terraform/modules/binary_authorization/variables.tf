variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "key_ring_id" {
  description = "ID of the KMS key ring that holds the attestor signing key"
  type        = string
}

variable "ci_sa_member" {
  description = "IAM member string for the CI service account that creates attestations"
  type        = string
}
