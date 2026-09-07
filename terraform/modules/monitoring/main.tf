resource "google_project_iam_audit_config" "cloud_run" {
  project = var.project_id
  service = "run.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

resource "google_project_iam_audit_config" "secret_manager" {
  project = var.project_id
  service = "secretmanager.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

resource "google_project_iam_audit_config" "kms" {
  project = var.project_id
  service = "cloudkms.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# --- Log-Based Metric: IAM Policy Changes ---

resource "google_logging_metric" "iam_changes" {
  project = var.project_id
  name    = "iam-policy-changes"
  filter  = "protoPayload.methodName=\"SetIamPolicy\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

# Cloud Monitoring registers a log-based metric descriptor lazily, up to 10
# minutes after Logging creates the metric. Referencing it before then fails
# with "does not represent a known descriptor".
resource "time_sleep" "metric_descriptor_propagation" {
  depends_on      = [google_logging_metric.iam_changes]
  create_duration = "10m"
}

# --- Notification Channel ---

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Aegis alerts"
  type         = "email"

  labels = {
    email_address = var.notification_email
  }
}

# --- Alert Policy: IAM Changes ---

resource "google_monitoring_alert_policy" "iam_changes" {
  project      = var.project_id
  display_name = "IAM policy changed"
  combiner     = "OR"
  depends_on   = [time_sleep.metric_descriptor_propagation]

  conditions {
    display_name = "IAM SetIamPolicy detected"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.iam_changes.name}\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]
}
