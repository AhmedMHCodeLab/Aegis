module "networking" {
  source = "./modules/networking"

  project_id = var.project_id
  region     = var.region
}

module "security" {
  source = "./modules/security"

  project_id         = var.project_id
  project_number     = var.project_number
  region             = var.region
  cloud_run_sa_email = module.iam.cloud_run_sa_email
}

module "iam" {
  source = "./modules/iam"

  project_id      = var.project_id
  crypto_key_id   = module.security.crypto_key_id
  github_owner_id = var.github_owner_id
  github_repo     = var.github_repo
}

module "artifact_registry" {
  source = "./modules/artifact_registry"

  project_id   = var.project_id
  region       = var.region
  kms_key_id   = module.security.crypto_key_id
  ci_sa_member = module.iam.ci_sa_member
}

module "cloud_run" {
  source = "./modules/cloud_run"

  project_id = var.project_id
  region     = var.region
  # Bootstrap only. Artifact Registry is empty on first apply, so the service is
  # created with a public placeholder. CI/CD pushes the real image and the
  # ignore_changes lifecycle in the module keeps Terraform from reverting it.
  image                 = "us-docker.pkg.dev/cloudrun/container/hello"
  service_account_email = module.iam.cloud_run_sa_email
  subnet_id             = module.networking.subnet_id
  network_id            = module.networking.network_id
  encryption_key        = module.security.crypto_key_id
  iap_user_email        = var.iap_user_email
  signing_key_secret_id = module.security.signing_key_secret_id
  ci_sa_member          = module.iam.ci_sa_member
}

module "binary_authorization" {
  source = "./modules/binary_authorization"

  project_id   = var.project_id
  key_ring_id  = module.security.key_ring_id
  ci_sa_member = module.iam.ci_sa_member
}

module "dns" {
  source = "./modules/dns"

  project_id             = var.project_id
  region                 = var.region
  cloud_run_service_name = module.cloud_run.service_name
}

module "monitoring" {
  source = "./modules/monitoring"

  project_id         = var.project_id
  notification_email = var.iap_user_email
}
