terraform {
  backend "gcs" {
    bucket = "aegis-prod-0926-tfstate"
    prefix = "terraform/bootstrap"
  }
}
