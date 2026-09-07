variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "crypto_key_id" {
  description = "KMS crypto key ID for granting runtime SA encrypter/decrypter access"
  type        = string
}

variable "wif_pool_name" {
  description = "Full resource name of the WIF pool, created by terraform/bootstrap"
  type        = string
}

variable "tfstate_bucket" {
  description = "GCS bucket holding Terraform state. CI cannot run init without object access to it."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format for WIF SA binding"
  type        = string
}
