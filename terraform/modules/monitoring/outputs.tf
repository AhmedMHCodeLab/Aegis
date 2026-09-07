output "notification_channel_name" {
  description = "Full resource name of the email notification channel"
  value       = google_monitoring_notification_channel.email.name
}

output "alert_policy_name" {
  description = "Full resource name of the IAM changes alert policy"
  value       = google_monitoring_alert_policy.iam_changes.name
}
