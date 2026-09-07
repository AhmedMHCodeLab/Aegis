variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "crypto_key_id" {
  description = "KMS crypto key ID for granting runtime SA encrypter/decrypter access"
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub user/org ID for WIF attribute condition (prevents typosquatting)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format for WIF SA binding"
  type        = string
}
