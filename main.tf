provider "google" {
  project = var.project_id
}

module "spanner" {
  source = "GoogleCloudPlatform/cloud-spanner/google"

  project_id            = var.project_id
  instance_name         = "multiregion-app-db"
  instance_config       = "nam3"
  instance_display_name = "Multi-Regional Application Spanner"
  instance_size = {
    num_nodes = 1
  }
  database_config = {
    "app-database" = {
      version_retention_period = "3d"
      ddl                      = []
      deletion_protection      = false
      database_iam             = []
      enable_backup            = false
      create_db                = true
    }
  }
}

variable "project_id" {
  description = "The GCP Project ID"
  type        = string
  default     = "avikuma-dev-04"
}

variable "regions" {
  description = "Regions for the multi-regional Cloud Run deployment"
  type        = list(string)
  default     = ["us-central1", "us-east1"]
}

variable "spanner_region" {
  description = "The region for the Spanner instance"
  type        = string
  default     = "us-central1"
}
