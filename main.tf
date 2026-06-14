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
  instance_config       = "nam-eur-asia1"
  instance_display_name = "Regional Application Spanner"
  instance_size = {
    num_nodes = 1
  }
  database_config = {
    "app-database" = {
      version_retention_period = "7d"
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
  ingress                = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

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
  destination_uri        = "bigquery.googleapis.com/projects/${var.project_id}/datasets/bq_org_${random_string.suffix.result}"
  filter                 = "severity >= ERROR"
  log_sink_name          = "storage_example_logsink"
  parent_resource_id     = "806869507256"
  parent_resource_type   = "organization"
  unique_writer_identity = true
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

module "destination" {
  source  = "terraform-google-modules/bigquery/google"
  version = "~> 7.0"

  dataset_id               = "bq_org_${random_string.suffix.result}"
  project_id               = var.project_id
  location                 = "US"
  max_time_travel_hours    = 168
  dataset_labels           = { environment = "prod" }
}

resource "google_project_iam_member" "bigquery_sink_member" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = module.log_export.writer_identity
}
