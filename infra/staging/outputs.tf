output "staging_project_id" {
  description = "Dedicated staging project."
  value       = var.staging_project_id
}

output "network" {
  description = "Private staging VPC self-link."
  value       = google_compute_network.staging.self_link
}

output "database_connection_name" {
  description = "Staging-only Cloud SQL connection name."
  value       = google_sql_database_instance.staging.connection_name
}

output "database_private_ip" {
  description = "Private Cloud SQL address for the distributed lane."
  value       = google_sql_database_instance.staging.private_ip_address
}

output "image_repository" {
  description = "Digest-only image repository for staging candidates."
  value       = "${var.region}-docker.pkg.dev/${var.staging_project_id}/${google_artifact_registry_repository.openagents.repository_id}/openagents"
}

output "builder_image_repository" {
  description = "Digest-only image repository for isolated staging builders."
  value       = "${var.region}-docker.pkg.dev/${var.staging_project_id}/${google_artifact_registry_repository.openagents.repository_id}/openagents-builder"
}

output "fleet_nodes" {
  description = "Exact BEAM node-to-instance map for runtime configuration."
  value = {
    for instance_name in sort(keys(local.nodes)) :
    "openagents@${instance_name}.staging.internal" => instance_name
  }
}

output "buckets" {
  description = "Staging-only durable storage buckets."
  value = {
    artifacts  = google_storage_bucket.artifacts.name
    evidence   = google_storage_bucket.evidence.name
    recordings = google_storage_bucket.recordings.name
    wal        = google_storage_bucket.wal.name
  }
}

output "service_accounts" {
  description = "Staging-only runtime identities."
  value = {
    deployer = google_service_account.deployer.email
    fleet    = google_service_account.fleet.email
    web      = google_service_account.web.email
  }
}
