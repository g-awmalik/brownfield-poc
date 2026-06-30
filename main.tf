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
# 2. MULTI-REGIONAL SPANNER INSTANCE (REMEDIATED FOR HIGH AVAILABILITY)
# ==============================================================================
module "spanner" {
  source = "GoogleCloudPlatform/cloud-spanner/google"

  project_id            = var.project_id
  instance_name         = "regional-app-db"
  instance_config       = "nam-eur-asia1" # Promoted from regional to multi-regional for 99.999% SLA and high-availability
  instance_display_name = "Regional Application Spanner"
  instance_size = {
    num_nodes = 1
  }
  database_config = {
    "app-database" = {
      version_retention_period = "7d" # Extended to 7 days (maximum duration) to secure PITR for logical recovery
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
# 3. MULTI-REGIONAL CLOUD RUN SERVICES (REMEDIATED INGRESS RESTRICTIONS)
# ==============================================================================
module "cloud_run" {
  source = "GoogleCloudPlatform/cloud-run/google//modules/v2"

  for_each = toset(var.regions)

  project_id             = var.project_id
  location               = each.key
  service_name           = "app-service-${each.key}"
  create_service_account = false
  service_account        = module.service_account.email
  ingress                = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" # Secures services by routing public traffic exclusively through the Global HTTP Load Balancer

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
# 4. GLOBAL LOAD BALANCER FRONTING CLOUD RUN (FRONTING SECURE INTERNAL CLOUD RUN)
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
# 5. LOG EXPORT (SINK - REMEDIATED TO ORGANIZATION-LEVEL AGGREGATED SINK)
# ==============================================================================

module "log_export" {
  source                 = "terraform-google-modules/log-export/google"
  version                = "~> 11.0"
  destination_uri        = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.dataset.dataset_id}"
  filter                 = "severity >= ERROR"
  log_sink_name          = "storage_example_logsink"
  parent_resource_id     = var.org_id       # Remediated to use designated Organization ID
  parent_resource_type   = "organization"   # Remediated to organization audit type for global visibility
  include_children       = true             # Enables child folder/project log aggregation
  unique_writer_identity = true
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

# -----------------
# API activation 
# -----------------
resource "google_project_service" "enable_destination_api" {
  project                    = var.project_id
  service                    = "bigquery.googleapis.com"
  disable_on_destroy         = false
  disable_dependent_services = false
}

# Native BigQuery Dataset Configuration with Remedated Max (7-Day) Time Travel
resource "google_bigquery_dataset" "dataset" {
  dataset_id                  = "bq_org_${random_string.suffix.result}"
  project                     = google_project_service.enable_destination_api.project
  location                    = "US"
  description                 = "Log export dataset"
  delete_contents_on_destroy  = false
  max_time_travel_hours       = 168 # Remediated: Set to the maximum (7-day / 168h) time travel recovery window for maximum logical reliability
}

resource "google_project_iam_member" "bigquery_sink_member" {
  project = google_bigquery_dataset.dataset.project
  role    = "roles/bigquery.dataEditor"
  member  = module.log_export.writer_identity
}
