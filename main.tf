provider "google" {
  project = var.project_id
}

# ==============================================================================
# 1. IAM & SERVICE ACCOUNTS
# ==============================================================================
module "service_account" {
  source  = "terraform-google-modules/service-accounts/google"
  version = "~> 4.0"

  project_id   = var.project_id
  names        = ["app-cloudrun-sa"]
  display_name = "Cloud Run App Service Account"
  description  = "Identity for Cloud Run to access Spanner"
}

# ==============================================================================
# 2. MULTI-REGIONAL SPANNER INSTANCE
# ==============================================================================
module "spanner" {
  source = "GoogleCloudPlatform/cloud-spanner/google"

  project_id            = var.project_id
  instance_name         = "multi-region-app-db"
  instance_config       = var.spanner_instance_config
  instance_display_name = "Multi-Region Application Spanner"
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

# Grant the Cloud Run Service Account access to the Spanner Database
resource "google_spanner_database_iam_member" "spanner_db_user" {
  project  = var.project_id
  instance = module.spanner.spanner_instance_id
  database = "app-database"
  role     = "roles/spanner.databaseUser"
  member   = "serviceAccount:${module.service_account.email}"
}

# ==============================================================================
# 3. MULTI-REGIONAL CLOUD RUN SERVICES (DIRECT PUBLIC ACCESS)
# ==============================================================================
module "cloud_run" {
  source = "GoogleCloudPlatform/cloud-run/google//modules/v2"

  for_each = toset(var.regions)

  project_id             = var.project_id
  location               = each.key
  service_name           = "app-service-${each.key}"
  create_service_account = false
  service_account        = module.service_account.email
  ingress                = "INGRESS_TRAFFIC_ALL"

  members = ["allUsers"]

  containers = [
    {
      container_image = var.container_image
      env_vars = {
        SPANNER_PROJECT_ID  = var.project_id
        SPANNER_INSTANCE_ID = element(split("/", module.spanner.spanner_instance_id), 3)
        SPANNER_DATABASE_ID = "app-database"
      }
    }
  ]
}
