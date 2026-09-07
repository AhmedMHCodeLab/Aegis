resource "google_compute_network" "main" {
  project                 = var.project_id
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "cloud_run" {
  project                  = var.project_id
  name                     = var.subnet_name
  network                  = google_compute_network.main.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_firewall" "deny_all_egress" {
  project   = var.project_id
  name      = "${var.vpc_name}-deny-all-egress"
  network   = google_compute_network.main.id
  direction = "EGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}

# Allow HTTPS to restricted.googleapis.com (VPC Service Controls range).
# Paired with the private DNS zone below that resolves *.googleapis.com here.
resource "google_compute_firewall" "allow_google_apis_egress" {
  project   = var.project_id
  name      = "${var.vpc_name}-allow-google-apis"
  network   = google_compute_network.main.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["199.36.153.4/30"]
}

# Private DNS zone: override *.googleapis.com to resolve to restricted.googleapis.com.
# Without this, Private Google Access traffic resolves to public Google IPs
# and the deny-all egress rule blocks it.
resource "google_dns_managed_zone" "googleapis" {
  project     = var.project_id
  name        = "googleapis"
  dns_name    = "googleapis.com."
  description = "Private zone routing Google API traffic to restricted.googleapis.com"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.main.id
    }
  }
}

resource "google_dns_record_set" "restricted_googleapis_cname" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["restricted.googleapis.com."]
}

resource "google_dns_record_set" "restricted_googleapis_a" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "restricted.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas = [
    "199.36.153.4",
    "199.36.153.5",
    "199.36.153.6",
    "199.36.153.7",
  ]
}

resource "google_dns_managed_zone" "pkg_dev" {
  project     = var.project_id
  name        = "pkg-dev"
  dns_name    = "pkg.dev."
  description = "Private zone routing Artifact Registry traffic to restricted.googleapis.com"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.main.id
    }
  }
}

resource "google_dns_record_set" "pkg_dev_cname" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.pkg_dev.name
  name         = "*.pkg.dev."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["pkg.dev."]
}

resource "google_dns_record_set" "pkg_dev_a" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.pkg_dev.name
  name         = "pkg.dev."
  type         = "A"
  ttl          = 300
  rrdatas = [
    "199.36.153.4",
    "199.36.153.5",
    "199.36.153.6",
    "199.36.153.7",
  ]
}

# gcr.io zone for distroless base image references.
resource "google_dns_managed_zone" "gcr_io" {
  project     = var.project_id
  name        = "gcr-io"
  dns_name    = "gcr.io."
  description = "Private zone routing Container Registry traffic to restricted.googleapis.com"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.main.id
    }
  }
}

resource "google_dns_record_set" "gcr_io_cname" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.gcr_io.name
  name         = "*.gcr.io."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["gcr.io."]
}

resource "google_dns_record_set" "gcr_io_a" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.gcr_io.name
  name         = "gcr.io."
  type         = "A"
  ttl          = 300
  rrdatas = [
    "199.36.153.4",
    "199.36.153.5",
    "199.36.153.6",
    "199.36.153.7",
  ]
}
