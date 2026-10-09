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
# 2. REGIONAL SPANNER INSTANCE
# ==============================================================================
module "spanner" {
  source = "GoogleCloudPlatform/cloud-spanner/google"

  project_id            = var.project_id
  instance_name         = "regional-app-db"
  instance_config       = "regional-${var.spanner_region}"
  instance_display_name = "Regional Application Spanner"
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

# ==============================================================================
# 4. GLOBAL LOAD BALANCER FRONTING CLOUD RUN
# ==============================================================================

# Serverless NEGs
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  for_each              = toset(var.regions)
  name                  = "serverless-neg-${each.key}"
  network_endpoint_type = "SERVERLESS"
  region                = each.key
  project               = var.project_id
  cloud_run {
    service = module.cloud_run[each.key].service_name
  }
}

module "lb-http" {
  source  = "GoogleCloudPlatform/lb-http/google//modules/serverless_negs"
  version = "~> 12.0"

  project = var.project_id
  name    = "global-app-lb"

  ssl                             = false
  managed_ssl_certificate_domains = []
  https_redirect                  = false

  backends = {
    default = {
      description = "Serverless NEGs routing to multi-regional Cloud Run"
      groups = [
        for neg in google_compute_region_network_endpoint_group.serverless_neg : {
          group = neg.id
        }
      ]
      enable_cdn              = false
      security_policy         = null
      custom_request_headers  = null
      custom_response_headers = null

      iap_config = {
        enable               = false
        oauth2_client_id     = ""
        oauth2_client_secret = ""
      }
      log_config = {
        enable      = false
        sample_rate = null
      }
    }
  }
}

# ==============================================================================
# 5. LOG EXPORT (SINK)
# ==============================================================================

module "log_export" {
  source                 = "terraform-google-modules/log-export/google"
  version                = "~> 11.0"
  destination_uri        = "${module.destination.destination_uri}"
  filter                 = "severity >= ERROR"
  log_sink_name          = "storage_example_logsink"
  parent_resource_id     = "sample-project"
  parent_resource_type   = "project"
  unique_writer_identity = true
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

module "destination" {
  source  = "terraform-google-modules/log-export/google//modules/bigquery"
  version = "~> 11.0"

  project_id               = var.project_id
  dataset_name             = "bq_org_${random_string.suffix.result}"
  log_sink_writer_identity = module.log_export.writer_identity
}
