variable "staging_project_id" {
  description = "Dedicated Google Cloud project for OpenAgents staging."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.staging_project_id)) &&
      can(regex("stag", var.staging_project_id))
    )
    error_message = "The staging project ID must be valid and contain 'stag'."
  }
}

variable "production_project_id" {
  description = "Production project ID used only by isolation safety checks."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.production_project_id)) &&
      var.production_project_id != var.staging_project_id
    )
    error_message = "The production project ID must be valid and differ from staging."
  }
}

variable "region" {
  description = "Region for all staging resources."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for stable staging fleet instances."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "The fleet zone must belong to the configured region."
  }
}

variable "network_cidr" {
  description = "Private subnet for the web and distributed staging lanes."
  type        = string
  default     = "10.42.0.0/24"
}

variable "database_tier" {
  description = "Cloud SQL machine tier with a staging-only connection budget."
  type        = string
  default     = "db-custom-1-3840"
}

variable "database_password" {
  description = "Write-only password for the staging application database role."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.database_password) >= 32 && length(var.database_password) <= 256
    error_message = "The staging database password must contain 32 through 256 characters."
  }
}

variable "database_password_version" {
  description = "Monotonic version that triggers write-only database password rotation."
  type        = number
  default     = 1

  validation {
    condition     = var.database_password_version >= 1 && floor(var.database_password_version) == var.database_password_version
    error_message = "The staging database password version must be a positive integer."
  }
}

variable "fleet_machine_type" {
  description = "Machine type for each distributed staging node."
  type        = string
  default     = "e2-standard-2"
}

variable "fleet_state_disk_gib" {
  description = "Durable state disk size for each distributed staging node."
  type        = number
  default     = 100

  validation {
    condition     = var.fleet_state_disk_gib >= 50 && var.fleet_state_disk_gib <= 1024
    error_message = "Fleet state disks must be between 50 and 1024 GiB."
  }
}

variable "iap_ssh_members" {
  description = "Operator principals allowed to use IAP and OS Login for staging."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for member in var.iap_ssh_members :
      can(regex("^(user|group):[^[:space:]]+$", member))
    ])
    error_message = "IAP members must use a user: or group: principal."
  }
}

variable "labels" {
  description = "Additional non-sensitive labels for staging resources."
  type        = map(string)
  default     = {}
}

variable "forge_mirror_urls_json" {
  description = "Optional JSON object from repository name to credential-free git mirror URL (e.g. {\"openagents.com\":\"https://github.com/OpenAgentsInc/openagents.com.git\"}). Empty disables mirroring."
  type        = string
  default     = ""
}
