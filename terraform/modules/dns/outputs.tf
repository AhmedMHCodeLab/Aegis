output "lb_ip_address" {
  description = "Static IP of the load balancer. The domain's A record points here."
  value       = var.lb_ip_address
}

output "lb_url" {
  description = "HTTPS URL through the load balancer"
  value       = "https://${var.domain}"
}

output "backend_service_id" {
  description = "Backend service ID, used for IAP and Cloud Armor references"
  value       = google_compute_backend_service.main.id
}
