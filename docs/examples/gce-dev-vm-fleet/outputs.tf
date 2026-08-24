output "instance_group_manager_self_link" {
  description = "Self link of the zonal development VM instance group manager."
  value       = google_compute_instance_group_manager.devvm.self_link
}

output "instance_group_manager_name" {
  description = "Name of the zonal development VM instance group manager."
  value       = google_compute_instance_group_manager.devvm.name
}

output "network_name" {
  description = "Name of the dedicated development VM VPC."
  value       = google_compute_network.devvm.name
}

output "subnetwork_name" {
  description = "Name of the dedicated development VM subnetwork."
  value       = google_compute_subnetwork.devvm.name
}

output "service_account_email" {
  description = "Service account attached to each development VM."
  value       = google_service_account.devvm.email
}

output "ssh_hint" {
  description = "Example command for an instance in the managed instance group."
  value       = "gcloud compute ssh --project=${var.project_id} --zone=${var.zone} INSTANCE_NAME --tunnel-through-iap"
}
