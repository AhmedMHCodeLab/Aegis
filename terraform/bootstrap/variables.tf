variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the key ring"
  type        = string
}

variable "key_ring_name" {
  description = "Name of the KMS key ring"
  type        = string
  default     = "aegis"
}

variable "rotation_period" {
  description = "Rotation period for the CMEK key in seconds. 90 days = 7776000s."
  type        = string
  default     = "7776000s"
}

variable "wif_pool_id" {
  description = "Workload Identity Pool ID"
  type        = string
  default     = "github-actions"
}

variable "wif_provider_id" {
  description = "Workload Identity Pool provider ID"
  type        = string
  default     = "aegis-repo"
}

variable "github_owner_id" {
  description = "Numeric GitHub user/org ID for the WIF attribute condition (prevents typosquatting)"
  type        = string
}
