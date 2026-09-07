variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for all regional resources"
  type        = string
}

variable "vpc_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "aegis-vpc"
}

variable "subnet_name" {
  description = "Name of the Cloud Run egress subnet"
  type        = string
  default     = "aegis-run"
}

variable "subnet_cidr" {
  description = "CIDR range for the Cloud Run egress subnet. Must be /26 or larger per Cloud Run direct VPC egress requirements."
  type        = string
  default     = "10.0.1.0/26"
}
