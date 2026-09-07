output "lb_ip_address" {
  description = "Static IP of the load balancer. Create a Route 53 A record pointing the domain here."
  value       = google_compute_global_address.main.address
}

output "lb_url" {
  description = "HTTPS URL through the load balancer"
  value       = "https://${var.domain}"
}

output "backend_service_id" {
  description = "Backend service ID, used for IAP and Cloud Armor references"
  value       = google_compute_backend_service.main.id
}
