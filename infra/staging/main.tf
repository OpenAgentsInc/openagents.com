locals {
  labels = merge(var.labels, {
    application = "openagents"
    environment = "staging"
    managed_by  = "terraform"
  })

  nodes = {
    "openagents-fleet-1" = "10.42.0.11"
    "openagents-fleet-2" = "10.42.0.12"
    "openagents-fleet-3" = "10.42.0.13"
  }

  required_services = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com"
  ])

  runtime_secrets = toset([
    "openagents-staging-web-config",
    "openagents-staging-fleet-config",
    "openagents-staging-builder-config",
    "openagents-staging-database-url",
    "openagents-staging-secret-key-base",
    "openagents-staging-github-client-secret",
    "openagents-staging-github-vault-active",
    "openagents-staging-github-vault-previous",
    "openagents-staging-openai-api-key",
    "openagents-staging-voice-recording-key",
    "openagents-staging-forge-operator-token",
    "openagents-staging-release-cookie"
  ])

  application_secrets = toset([
    "openagents-staging-database-url",
    "openagents-staging-secret-key-base",
    "openagents-staging-github-client-secret",
    "openagents-staging-github-vault-active",
    "openagents-staging-github-vault-previous",
    "openagents-staging-openai-api-key",
    "openagents-staging-voice-recording-key",
    "openagents-staging-forge-operator-token",
    "openagents-staging-release-cookie"
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_services

  project            = var.staging_project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "staging" {
  name                    = "openagents-staging"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "staging" {
  name                     = "openagents-staging-${var.region}"
  ip_cidr_range            = var.network_cidr
  region                   = var.region
  network                  = google_compute_network.staging.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_global_address" "private_services" {
  name          = "openagents-staging-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.staging.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.staging.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]

  depends_on = [google_project_service.required]
}

resource "google_compute_router" "staging" {
  name    = "openagents-staging"
  region  = var.region
  network = google_compute_network.staging.id
}

resource "google_compute_router_nat" "staging" {
  name                               = "openagents-staging"
  router                             = google_compute_router.staging.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.staging.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_dns_managed_zone" "staging_private" {
  name        = "openagents-staging-internal"
  dns_name    = "staging.internal."
  description = "Private service discovery for isolated OpenAgents staging."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.staging.id
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_compute_address" "fleet" {
  for_each = local.nodes

  name         = each.key
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.staging.id
  address      = each.value
}

resource "google_dns_record_set" "fleet_nodes" {
  for_each = local.nodes

  name         = "${each.key}.staging.internal."
  type         = "A"
  ttl          = 30
  managed_zone = google_dns_managed_zone.staging_private.name
  rrdatas      = [google_compute_address.fleet[each.key].address]
}

resource "google_dns_record_set" "fleet_discovery" {
  name         = "openagents-fleet.staging.internal."
  type         = "A"
  ttl          = 30
  managed_zone = google_dns_managed_zone.staging_private.name
  rrdatas      = [for node in sort(keys(local.nodes)) : google_compute_address.fleet[node].address]
}

resource "google_dns_record_set" "deployer" {
  name         = "openagents-deployer.staging.internal."
  type         = "A"
  ttl          = 30
  managed_zone = google_dns_managed_zone.staging_private.name
  rrdatas      = [google_compute_address.deployer.address]
}

resource "google_compute_firewall" "fleet_internal" {
  name      = "openagents-staging-fleet-internal"
  network   = google_compute_network.staging.name
  direction = "INGRESS"
  priority  = 900

  source_ranges = [var.network_cidr]
  target_tags   = ["openagents-staging-fleet", "openagents-staging-controller"]

  allow {
    protocol = "tcp"
    ports    = ["4000", "4369", "9100-9115"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "iap_ssh" {
  name      = "openagents-staging-iap-ssh"
  network   = google_compute_network.staging.name
  direction = "INGRESS"
  priority  = 900

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["openagents-staging-fleet"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_service_account" "web" {
  account_id   = "openagents-staging-web"
  display_name = "OpenAgents staging web"
  description  = "Runs only the staging web acceptance lane."
}

resource "google_service_account" "fleet" {
  account_id   = "openagents-staging-fleet"
  display_name = "OpenAgents staging fleet"
  description  = "Runs only the three staging BEAM nodes."
}

resource "google_service_account" "deployer" {
  account_id   = "openagents-staging-deployer"
  display_name = "OpenAgents staging deployer"
  description  = "Performs one-node-at-a-time replacement in staging."
}

resource "google_project_iam_member" "web" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter"
  ])

  project = var.staging_project_id
  role    = each.value
  member  = google_service_account.web.member
}

resource "google_project_iam_member" "fleet" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/cloudsql.client",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter"
  ])

  project = var.staging_project_id
  role    = each.value
  member  = google_service_account.fleet.member
}

resource "google_project_iam_custom_role" "deployer" {
  role_id     = "openagentsStagingDeployer"
  title       = "OpenAgents staging deployer"
  description = "Resets one staging fleet instance after updating its exact image metadata."
  stage       = "GA"

  permissions = [
    "compute.instances.get",
    "compute.instances.reset",
    "compute.instances.setMetadata",
    "compute.zoneOperations.get"
  ]
}

resource "google_project_iam_member" "deployer" {
  project = var.staging_project_id
  role    = google_project_iam_custom_role.deployer.id
  member  = google_service_account.deployer.member
}

resource "google_project_iam_member" "deployer_runtime" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter"
  ])

  project = var.staging_project_id
  role    = each.value
  member  = google_service_account.deployer.member
}

resource "google_project_iam_member" "iap_tunnel" {
  for_each = var.iap_ssh_members

  project = var.staging_project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = each.value
}

resource "google_project_iam_member" "os_login" {
  for_each = var.iap_ssh_members

  project = var.staging_project_id
  role    = "roles/compute.osLogin"
  member  = each.value
}

resource "google_secret_manager_secret" "runtime" {
  for_each = local.runtime_secrets

  secret_id = each.value
  labels    = local.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "web_env" {
  secret_id = google_secret_manager_secret.runtime["openagents-staging-web-config"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.web.member
}

resource "google_secret_manager_secret_iam_member" "fleet_env" {
  secret_id = google_secret_manager_secret.runtime["openagents-staging-fleet-config"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.fleet.member
}

resource "google_secret_manager_secret_iam_member" "builder_env" {
  secret_id = google_secret_manager_secret.runtime["openagents-staging-builder-config"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.fleet.member
}

resource "google_secret_manager_secret_iam_member" "web_secrets" {
  for_each = local.application_secrets

  secret_id = google_secret_manager_secret.runtime[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.web.member
}

resource "google_secret_manager_secret_iam_member" "fleet_secrets" {
  for_each = local.application_secrets

  secret_id = google_secret_manager_secret.runtime[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.fleet.member
}

resource "google_secret_manager_secret_iam_member" "deployer_cookie" {
  secret_id = google_secret_manager_secret.runtime["openagents-staging-release-cookie"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.deployer.member
}

resource "google_artifact_registry_repository" "openagents" {
  location      = var.region
  repository_id = "openagents-staging"
  description   = "Immutable OpenAgents staging release and builder images."
  format        = "DOCKER"
  labels        = local.labels

  cleanup_policy_dry_run = true
  deletion_policy        = "PREVENT"

  docker_config {
    immutable_tags = true
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "artifacts" {
  name                        = "${var.staging_project_id}-openagents-artifacts"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "wal" {
  name                        = "${var.staging_project_id}-openagents-forge-wal"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "recordings" {
  name                        = "${var.staging_project_id}-openagents-recordings"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket" "evidence" {
  name                        = "${var.staging_project_id}-openagents-evidence"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  versioning {
    enabled = true
  }

  retention_policy {
    retention_period = 2592000
    is_locked        = false
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket_iam_member" "fleet_artifacts" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.fleet.member
}

resource "google_storage_bucket_iam_member" "fleet_wal" {
  bucket = google_storage_bucket.wal.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.fleet.member
}

resource "google_storage_bucket_iam_member" "web_recordings" {
  bucket = google_storage_bucket.recordings.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.web.member
}

resource "google_storage_bucket_iam_member" "fleet_recordings" {
  bucket = google_storage_bucket.recordings.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.fleet.member
}

resource "google_storage_bucket_iam_member" "deployer_evidence" {
  bucket = google_storage_bucket.evidence.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.deployer.member
}

resource "google_sql_database_instance" "staging" {
  name                = "openagents-staging-postgres"
  region              = var.region
  database_version    = "POSTGRES_17"
  deletion_protection = true

  settings {
    edition                     = "ENTERPRISE"
    tier                        = var.database_tier
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 20
    disk_autoresize             = true
    deletion_protection_enabled = true
    user_labels                 = local.labels

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "05:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.staging.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
    }

    maintenance_window {
      day          = 7
      hour         = 6
      update_track = "stable"
    }
  }

  depends_on = [
    google_project_service.required,
    google_service_networking_connection.private_services
  ]
}

resource "google_sql_database" "openagents" {
  name            = "openagents_staging"
  instance        = google_sql_database_instance.staging.name
  deletion_policy = "ABANDON"
}

resource "google_sql_user" "openagents" {
  name                = "openagents_staging"
  instance            = google_sql_database_instance.staging.name
  password_wo         = var.database_password
  password_wo_version = var.database_password_version
  deletion_policy     = "ABANDON"
}

data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "google_compute_disk" "fleet_state" {
  for_each = local.nodes

  name   = "${each.key}-state"
  type   = "pd-balanced"
  zone   = var.zone
  size   = var.fleet_state_disk_gib
  labels = local.labels

  depends_on = [google_project_service.required]
}

resource "google_compute_instance" "fleet" {
  for_each = local.nodes

  name                      = each.key
  zone                      = var.zone
  machine_type              = var.fleet_machine_type
  allow_stopping_for_update = true
  can_ip_forward            = false
  deletion_protection       = true
  tags                      = ["openagents-staging-fleet"]
  labels                    = merge(local.labels, { lane = "distributed" })

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.cos.self_link
      size  = 20
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_disk.fleet_state[each.key].id
    device_name = "openagents-state"
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.staging.id
    network_ip = google_compute_address.fleet[each.key].address
  }

  metadata = {
    block-project-ssh-keys    = "TRUE"
    enable-oslogin            = "TRUE"
    openagents-environment    = "staging"
    openagents-image          = ""
    openagents-image-digest   = ""
    openagents-builder-image  = ""
    openagents-builder-digest = ""
    openagents-sha            = ""
    openagents-runtime-secret = google_secret_manager_secret.runtime["openagents-staging-fleet-config"].secret_id
    openagents-builder-secret = google_secret_manager_secret.runtime["openagents-staging-builder-config"].secret_id
    startup-script = templatefile("${path.module}/templates/fleet-startup.sh.tftpl", {
      project_id = var.staging_project_id
      region     = var.region
    })
  }

  service_account {
    email  = google_service_account.fleet.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  depends_on = [
    google_project_service.required,
    google_compute_router_nat.staging,
    google_secret_manager_secret_iam_member.fleet_env
  ]
}

resource "google_compute_address" "deployer" {
  name         = "openagents-staging-deployer"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.staging.id
  address      = "10.42.0.20"
}

resource "google_compute_instance" "deployer" {
  name                      = "openagents-staging-deployer"
  zone                      = var.zone
  machine_type              = "e2-small"
  allow_stopping_for_update = true
  can_ip_forward            = false
  deletion_protection       = true
  tags                      = ["openagents-staging-controller"]
  labels                    = merge(local.labels, { lane = "deployer" })

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.cos.self_link
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.staging.id
    network_ip = google_compute_address.deployer.address
  }

  metadata = {
    block-project-ssh-keys      = "TRUE"
    enable-oslogin              = "TRUE"
    openagents-environment      = "staging"
    openagents-controller-image = ""
    openagents-controller-sha   = ""
    openagents-cookie-secret    = google_secret_manager_secret.runtime["openagents-staging-release-cookie"].secret_id
    startup-script = templatefile("${path.module}/templates/deployer-startup.sh.tftpl", {
      project_id = var.staging_project_id
      region     = var.region
    })
  }

  service_account {
    email  = google_service_account.deployer.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  depends_on = [
    google_project_service.required,
    google_compute_router_nat.staging,
    google_project_iam_member.deployer,
    google_secret_manager_secret_iam_member.deployer_cookie
  ]
}
