variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the Cloud Run service"
  type        = string
}

variable "service_name" {
  description = "Name of the Cloud Run service"
  type        = string
  default     = "aegis"
}

variable "image" {
  description = "Container image URL from Artifact Registry"
  type        = string
}

variable "service_account_email" {
  description = "Email of the runtime service account (aegis-run)"
  type        = string
}

variable "subnet_id" {
  description = "Self-link of the VPC subnet for direct VPC egress"
  type        = string
}

variable "network_id" {
  description = "Self-link of the VPC network for direct VPC egress"
  type        = string
}

variable "encryption_key" {
  description = "KMS crypto key ID for CMEK encryption of revisions"
  type        = string
}

variable "max_instance_count" {
  description = "Maximum number of instances"
  type        = number
  default     = 4
}

variable "iap_user_email" {
  description = "Email of the user granted access through IAP"
  type        = string
}

variable "signing_key_secret_id" {
  description = "Secret Manager secret ID for the HMAC signing key"
  type        = string
}

variable "ci_sa_member" {
  description = "IAM member string for the CI SA, granted roles/run.developer"
  type        = string
}
