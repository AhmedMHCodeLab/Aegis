output "network_id" {
  description = "Self-link of the VPC network"
  value       = google_compute_network.main.id
}

output "network_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.main.name
}

output "subnet_id" {
  description = "Self-link of the Cloud Run egress subnet"
  value       = google_compute_subnetwork.cloud_run.id
}

output "subnet_name" {
  description = "Name of the Cloud Run egress subnet"
  value       = google_compute_subnetwork.cloud_run.name
}
