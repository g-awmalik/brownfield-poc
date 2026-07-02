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
# 2. MULTI-REGIONAL SPANNER INSTANCE (nam-eur-asia1 config for Multi-region)
# ==============================================================================
module "spanner" {
  source = "GoogleCloudPlatform/cloud-spanner/google"

  project_id            = var.project_id
  instance_name         = "regional-app-db"
  instance_config       = "nam-eur-asia1"
  instance_display_name = "Multi-Region Application Spanner"
  instance_size = {
    num_nodes = 1
  }
  database_config = {
    "app-database" = {
      version_retention_period = "7d" # Meets PITR requirement (up to 7 days)
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
# 3. MULTI-REGIONAL CLOUD RUN SERVICES (DIRECT PUBLIC ACCESS + VPC EGRESS CONFIG)
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

  # Direct VPC Egress configuration satisfying "Allowed VPC Egress Settings"
  vpc_access = {
    egress = "ALL_TRAFFIC"
    network_interfaces = {
      network    = "default"
      subnetwork = "default"
    }
  }

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
# 4. GLOBAL LOAD BALANCER FRONTING CLOUD RUN (HTTPS Redirect, SSL and Term Timeout)
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

  ssl                             = true
  managed_ssl_certificate_domains = ["example.com"]
  https_redirect                  = true
  http_keep_alive_timeout_sec     = 600

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
# 5. CUSTOMER-MANAGED ENCRYPTION KEYS (KMS for BigQuery CMEK)
# ==============================================================================
resource "google_kms_key_ring" "key_ring" {
  name     = "app-key-ring-${random_string.suffix.result}"
  location = "us" # Matches US location of modern BigQuery dataset
  project  = var.project_id
}

resource "google_kms_crypto_key" "kms_key" {
  name     = "app-key-${random_string.suffix.result}"
  key_ring = google_kms_key_ring.key_ring.id
  purpose  = "ENCRYPT_DECRYPT"
}

data "google_bigquery_default_service_account" "bq_sa" {
  project = var.project_id
}

resource "google_kms_crypto_key_iam_member" "bq_kms" {
  crypto_key_id = google_kms_crypto_key.kms_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_bigquery_default_service_account.bq_sa.email}"
}

# ==============================================================================
# 6. SECURE BIGQUERY DATASET FOR LOGS (Direct Resource for Advanced Properties)
# ==============================================================================
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

resource "google_bigquery_dataset" "dataset" {
  dataset_id                  = "bq_org_${random_string.suffix.result}"
  project                     = var.project_id
  location                    = "US"
  description                 = "Secure Log export dataset"
  delete_contents_on_destroy  = false
  max_time_travel_hours       = "168" # Meets 7-day maximum time travel requirement

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.kms_key.id # Meets CMEK encryption constraint
  }
}

# Explicit dataset access control ensuring PUBLIC_DATASET risk mitigation
resource "google_bigquery_dataset_access" "owners" {
  project       = var.project_id
  dataset_id    = google_bigquery_dataset.dataset.dataset_id
  role          = "OWNER"
  special_group = "projectOwners"
}

resource "google_bigquery_dataset_access" "writers" {
  project       = var.project_id
  dataset_id    = google_bigquery_dataset.dataset.dataset_id
  role          = "WRITER"
  special_group = "projectWriters"
}

resource "google_bigquery_dataset_access" "readers" {
  project       = var.project_id
  dataset_id    = google_bigquery_dataset.dataset.dataset_id
  role          = "READER"
  special_group = "projectReaders"
}

resource "google_bigquery_dataset_access" "sink" {
  project       = var.project_id
  dataset_id    = google_bigquery_dataset.dataset.dataset_id
  role          = "WRITER"
  user_by_email = element(split(":", module.log_export.writer_identity), 1)
}

resource "google_project_iam_member" "bigquery_sink_member" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = module.log_export.writer_identity
}

# ==============================================================================
# 7. LOG EXPORT (AGGREGATED ORGANIZATIONAL SINK)
# ==============================================================================
module "log_export" {
  source                 = "terraform-google-modules/log-export/google"
  version                = "~> 11.0"
  destination_uri        = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.dataset.dataset_id}"
  filter                 = "severity >= ERROR"
  log_sink_name          = "storage_example_logsink"
  parent_resource_id     = "806869507256" # Restores aggregate compliance at Org level
  parent_resource_type   = "organization"
  unique_writer_identity = true
  include_children       = true # Aggregated sink
}
