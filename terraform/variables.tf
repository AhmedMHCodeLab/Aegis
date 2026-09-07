variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "project_number" {
  description = "GCP project number"
  type        = string
}

variable "region" {
  description = "GCP region for all regional resources"
  type        = string
}

variable "iap_user_email" {
  description = "Email of the user granted access through IAP"
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub user/org ID for WIF attribute condition"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format"
  type        = string
}

variable "key_ring_name" {
  description = "Name of the KMS key ring created by terraform/bootstrap"
  type        = string
  default     = "aegis"
}

variable "lb_address_name" {
  description = "Name of the reserved global address created by terraform/bootstrap"
  type        = string
  default     = "aegis-lb-ip"
}

variable "wif_pool_id" {
  description = "Workload Identity Pool ID created by terraform/bootstrap"
  type        = string
  default     = "github-actions"
}
