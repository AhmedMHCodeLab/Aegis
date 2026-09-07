variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region where Cloud Run service runs"
  type        = string
}

variable "service_name" {
  description = "Base name for all edge resources"
  type        = string
  default     = "aegis"
}

variable "domain" {
  description = "Domain for the managed SSL certificate"
  type        = string
  default     = "aegis.ahmedmhcodelab.click"
}

variable "cloud_run_service_name" {
  description = "Name of the Cloud Run service to front with the LB"
  type        = string
}

variable "lb_ip_address" {
  description = "Reserved global IP, created by terraform/bootstrap"
  type        = string
}

variable "enable_cloud_armor" {
  description = "Create Cloud Armor security policy. Requires SECURITY_POLICIES quota > 0."
  type        = bool
  default     = false
}
