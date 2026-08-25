mock_provider "google" {}

run "isolated_topology" {
  command = plan

  variables {
    staging_project_id    = "openagents-staging-test"
    production_project_id = "openagents-production"
    database_password     = "test-only-database-password-000000000000"
  }

  assert {
    condition     = length(google_compute_instance.fleet) == 3
    error_message = "The distributed staging lane must contain exactly three nodes."
  }

  assert {
    condition = alltrue([
      for instance in values(google_compute_instance.fleet) :
      length(instance.network_interface[0].access_config) == 0
    ])
    error_message = "Staging fleet nodes must not have public access configurations."
  }

  assert {
    condition = alltrue([
      for instance in values(google_compute_instance.fleet) :
      strcontains(
        instance.metadata["startup-script"],
        "--volume \"$state_root/artifacts:$state_root/artifacts\""
      )
    ])
    error_message = "The isolated Forge builder must share the artifact directory with the application."
  }

  assert {
    condition     = length(google_compute_instance.deployer.network_interface[0].access_config) == 0
    error_message = "The staging deployer must not have a public access configuration."
  }

  assert {
    condition = strcontains(
      google_compute_instance.deployer.metadata["startup-script"],
      "-hidden"
    )
    error_message = "The staging deployer must use a hidden Erlang node so it can probe every fleet member without joining the global cluster."
  }

  assert {
    condition = alltrue([
      strcontains(google_compute_instance.deployer.metadata["startup-script"], "OPENAGENTS_GCP_ROLLING_PROJECT_ID"),
      strcontains(google_compute_instance.deployer.metadata["startup-script"], "OPENAGENTS_GCP_ROLLING_INSTANCES_JSON"),
      strcontains(google_compute_instance.deployer.metadata["startup-script"], "OPENAGENTS_PRODUCTION_PROJECT_ID")
    ])
    error_message = "The staging deployer must receive its bounded, non-secret rolling-provider inventory."
  }

  assert {
    condition = strcontains(
      google_compute_instance.fleet["openagents-fleet-1"].metadata["startup-script"],
      "docker image prune --all --force"
    )
    error_message = "Fleet startup must reclaim only unused registry-backed images before pulling a candidate."
  }

  assert {
    condition     = google_sql_database_instance.staging.deletion_protection
    error_message = "The staging database must keep Terraform deletion protection enabled."
  }

  assert {
    condition     = google_sql_database_instance.staging.settings[0].ip_configuration[0].ipv4_enabled == false
    error_message = "The staging database must not expose a public IPv4 address."
  }

  assert {
    condition     = google_sql_user.openagents.name == "openagents_staging"
    error_message = "Staging must have a separate application database role."
  }

  assert {
    condition     = google_artifact_registry_repository.openagents.docker_config[0].immutable_tags
    error_message = "Staging application and builder image tags must be immutable."
  }

  assert {
    condition     = google_artifact_registry_repository.openagents.deletion_policy == "PREVENT"
    error_message = "Terraform must not delete the staging artifact repository."
  }

  assert {
    condition     = length(google_secret_manager_secret.runtime) == 16
    error_message = "Every named staging credential and lane configuration needs its own secret resource."
  }

  assert {
    condition = alltrue([
      for binding in values(google_secret_manager_secret_iam_member.scv_codex_credential_add) :
      binding.role == "roles/secretmanager.secretVersionAdder"
    ])
    error_message = "The staging web identity may add versions only to the preallocated SCV Codex credential slots."
  }

  assert {
    condition = alltrue([
      for binding in values(google_secret_manager_secret_iam_member.scv_codex_credential_read) :
      binding.role == "roles/secretmanager.secretAccessor"
    ])
    error_message = "The staging web identity may read exact versions only from the preallocated SCV Codex credential slots."
  }

  assert {
    condition = alltrue([
      for binding in values(google_secret_manager_secret_iam_member.fleet_scv_codex_credential_add) :
      binding.role == "roles/secretmanager.secretVersionAdder"
    ])
    error_message = "The staging fleet identity may add versions only to the preallocated SCV Codex credential slots."
  }

  assert {
    condition = alltrue([
      for binding in values(google_secret_manager_secret_iam_member.fleet_scv_codex_credential_read) :
      binding.role == "roles/secretmanager.secretAccessor"
    ])
    error_message = "The staging fleet identity may read exact versions only from the preallocated SCV Codex credential slots."
  }

  assert {
    condition = toset(google_project_iam_custom_role.deployer.permissions) == toset([
      "compute.instances.get",
      "compute.instances.reset",
      "compute.instances.setMetadata",
      "compute.zoneOperations.get"
    ])
    error_message = "The deployer role must retain its bounded Compute permission set."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.deployer_cookie.role == "roles/secretmanager.secretAccessor"
    error_message = "The deployer identity may read only the cluster cookie secret."
  }

  assert {
    condition     = google_service_account_iam_member.deployer_fleet_act_as.role == "roles/iam.serviceAccountUser"
    error_message = "The deployer may act as only the exact staging fleet service account required by Compute metadata updates."
  }
}

run "rejects_production_project" {
  command = plan

  variables {
    staging_project_id    = "openagents-staging-test"
    production_project_id = "openagents-staging-test"
    database_password     = "test-only-database-password-000000000000"
  }

  expect_failures = [var.production_project_id]
}

run "rejects_unmarked_project" {
  command = plan

  variables {
    staging_project_id    = "openagents-testing"
    production_project_id = "openagents-production"
    database_password     = "test-only-database-password-000000000000"
  }

  expect_failures = [var.staging_project_id]
}
