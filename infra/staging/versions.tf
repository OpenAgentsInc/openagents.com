terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.41"
    }
  }

  backend "gcs" {
    prefix = "openagents/staging"
  }
}

provider "google" {
  project = var.staging_project_id
  region  = var.region
  zone    = var.zone
}
