locals {
  labels = merge(var.labels, {
    application = "openagents"
    environment = "development"
    managed_by  = "terraform"
  })

  iap_tcp_forwarding_range = "35.235.240.0/20"
}

data "google_compute_image" "ubuntu" {
  family  = var.image_family
  project = var.image_project
}

resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "iap.googleapis.com"
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "devvm" {
  name                    = "openagents-devvm"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "devvm" {
  name                     = "openagents-devvm-${var.region}"
  ip_cidr_range            = "10.42.0.0/24"
  region                   = var.region
  network                  = google_compute_network.devvm.id
  private_ip_google_access = true
}

resource "google_compute_router" "devvm" {
  name    = "openagents-devvm"
  region  = var.region
  network = google_compute_network.devvm.id
}

resource "google_compute_router_nat" "devvm" {
  name                               = "openagents-devvm"
  router                             = google_compute_router.devvm.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.devvm.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "iap_ssh" {
  name      = "openagents-devvm-iap-ssh"
  network   = google_compute_network.devvm.name
  direction = "INGRESS"
  priority  = 900

  source_ranges = [local.iap_tcp_forwarding_range]
  target_tags   = ["openagents-devvm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_service_account" "devvm" {
  account_id   = "openagents-devvm"
  display_name = "OpenAgents development VM fleet"
  description  = "Runs the example development VM fleet with logging and monitoring write access."
}

resource "google_project_iam_member" "devvm" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter"
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.devvm.member
}

resource "google_compute_instance_template" "devvm" {
  name_prefix  = "openagents-devvm-"
  machine_type = var.machine_type
  labels       = local.labels
  tags         = ["openagents-devvm"]

  disk {
    auto_delete  = true
    boot         = true
    disk_size_gb = var.boot_disk_size_gb
    disk_type    = var.boot_disk_type
    source_image = data.google_compute_image.ubuntu.self_link
  }

  network_interface {
    subnetwork = google_compute_subnetwork.devvm.self_link
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  service_account {
    email  = google_service_account.devvm.email
    scopes = ["cloud-platform"]
  }

  advanced_machine_features {
    enable_nested_virtualization = var.enable_nested_virtualization
  }

  metadata_startup_script = file("${path.module}/bootstrap.sh")

  lifecycle {
    create_before_destroy = true

    precondition {
      condition = !(
        var.enable_nested_virtualization &&
        startswith(var.machine_type, "e2-")
      )
      error_message = "Nested virtualization is not supported on E2 machine types."
    }
  }

  depends_on = [google_project_iam_member.devvm]
}

resource "google_compute_instance_group_manager" "devvm" {
  name               = "openagents-devvm"
  zone               = var.zone
  base_instance_name = "openagents-devvm"
  target_size        = var.fleet_size

  version {
    instance_template = google_compute_instance_template.devvm.self_link
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
    replacement_method    = "SUBSTITUTE"
  }
}
