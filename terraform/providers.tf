terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "google" {
  project                = var.project_id
  region                 = var.region
  user_project_override  = true
  billing_project        = var.project_id
}

provider "google-beta" {
  project                = var.project_id
  region                 = var.region
  user_project_override  = true
  billing_project        = var.project_id
}
