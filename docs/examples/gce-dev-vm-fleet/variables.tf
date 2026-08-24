variable "project_id" {
  description = "Google Cloud project that owns the development VM fleet."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "The project ID must contain 6 through 30 lowercase letters, digits, or hyphens, start with a letter, and end with a letter or digit."
  }
}

variable "region" {
  description = "Region for the VPC, Cloud NAT, and development VM fleet."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the zonal development VM fleet."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "The fleet zone must belong to the configured region."
  }
}

variable "fleet_size" {
  description = "Number of development VMs in the fleet."
  type        = number
  default     = 10

  validation {
    condition     = var.fleet_size >= 1 && var.fleet_size <= 50 && floor(var.fleet_size) == var.fleet_size
    error_message = "The fleet size must be an integer from 1 through 50."
  }
}

variable "machine_type" {
  description = "Compute Engine instance type for each development VM."
  type        = string
  default     = "n2-standard-8"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size for each development VM."
  type        = number
  default     = 128

  validation {
    condition     = var.boot_disk_size_gb >= 64 && floor(var.boot_disk_size_gb) == var.boot_disk_size_gb
    error_message = "The boot disk size must be an integer of at least 64 GB."
  }
}

variable "boot_disk_type" {
  description = "Persistent disk type for each development VM boot disk."
  type        = string
  default     = "pd-balanced"
}

variable "image_family" {
  description = "Ubuntu image family used for the boot disk."
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "image_project" {
  description = "Google Cloud project that publishes the Ubuntu image family."
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "enable_nested_virtualization" {
  description = "Enable nested virtualization for workloads such as Cloud Hypervisor or Firecracker."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Additional non-sensitive labels for the fleet resources."
  type        = map(string)
  default     = {}
}
