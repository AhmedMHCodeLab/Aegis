# The global address is owned by terraform/bootstrap so that destroying and
# rebuilding this stack does not reallocate the IP and break DNS.

# --- SSL ---

resource "google_compute_managed_ssl_certificate" "main" {
  project = var.project_id
  name    = "${var.service_name}-cert"

  managed {
    domains = [var.domain]
  }
}

resource "google_compute_ssl_policy" "main" {
  project         = var.project_id
  name            = "${var.service_name}-ssl-policy"
  profile         = "RESTRICTED"
  min_tls_version = "TLS_1_2"
}

# --- Serverless NEG ---

resource "google_compute_region_network_endpoint_group" "main" {
  project               = var.project_id
  name                  = "${var.service_name}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.cloud_run_service_name
  }
}

# --- Cloud Armor (gated on quota availability) ---

resource "google_compute_security_policy" "main" {
  count   = var.enable_cloud_armor ? 1 : 0
  project = var.project_id
  name    = "${var.service_name}-waf"

  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection"
  }

  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
    description = "Block cross-site scripting"
  }

  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
    }
    description = "Rate limit: 100 req/min per IP"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}

# --- Backend Service (IAP is on Cloud Run directly) ---

resource "google_compute_backend_service" "main" {
  project = var.project_id
  name    = "${var.service_name}-backend"

  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = var.enable_cloud_armor ? google_compute_security_policy.main[0].id : null

  backend {
    group = google_compute_region_network_endpoint_group.main.id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# --- URL Map ---

resource "google_compute_url_map" "main" {
  project         = var.project_id
  name            = "${var.service_name}-url-map"
  default_service = google_compute_backend_service.main.id
}

# --- HTTPS Proxy ---

resource "google_compute_target_https_proxy" "main" {
  project          = var.project_id
  name             = "${var.service_name}-https-proxy"
  url_map          = google_compute_url_map.main.id
  ssl_certificates = [google_compute_managed_ssl_certificate.main.id]
  ssl_policy       = google_compute_ssl_policy.main.id
}

# --- Forwarding Rule ---

resource "google_compute_global_forwarding_rule" "main" {
  project               = var.project_id
  name                  = "${var.service_name}-https-rule"
  target                = google_compute_target_https_proxy.main.id
  ip_address            = var.lb_ip_address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
