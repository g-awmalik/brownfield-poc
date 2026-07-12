provider "google" {
  project = var.project_id
}

provider "google-beta" {
  project = var.project_id
}

# ==============================================================================
# 0. LOCALS & UTILITIES
# ==============================================================================
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  dataset_id = "bq_org_${random_string.suffix.result}"
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
  instance_config       = "nam-eur-asia1"
  instance_display_name = "Multi-Region Application Spanner"
  instance_size = {
    num_nodes = 1
  }
  database_config = {
    "app-database" = {
      version_retention_period = "7d"
      ddl                      = []
      deletion_protection      = false
      database_iam             = []
      enable_backup            = true
      backup_retention         = "604800s"
      create_db                = true
    }
  }
}

resource "google_spanner_database_iam_member" "spanner_db_user" {
  project  = var.project_id
  instance = module.spanner.spanner_instance_id
  database = "app-database"
  role     = "roles/spanner.databaseUser"
  member   = "serviceAccount:${module.service_account.email}"
}

# ==============================================================================
# 3. NETWORKING (VPC ACCESS CONNECTOR FOR CLOUD RUN EGRESS)
# ==============================================================================
resource "google_vpc_access_connector" "connector" {
  for_each = toset(var.regions)
  name     = "run-conn-${each.key}"
  region   = each.key
  project  = var.project_id
  
  # Using a reserved range for the connector
  ip_cidr_range = each.key == "us-central1" ? "10.8.0.0/28" : "10.9.0.0/28"
  network       = "default"
}

# ==============================================================================
# 4. MULTI-REGIONAL CLOUD RUN SERVICES
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

  # Properly configured VPC egress with connector
  vpc_access = {
    connector = google_vpc_access_connector.connector[each.key].id
    egress    = "ALL_TRAFFIC"
  }

  members = []

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
# 5. GLOBAL LOAD BALANCER
# ==============================================================================
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

resource "google_compute_ssl_certificate" "example" {
  name        = "cert-${random_string.suffix.result}"
  private_key = tls_private_key.example.private_key_pem
  certificate = tls_self_signed_cert.example.cert_pem
  project     = var.project_id
}

resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "example" {
  private_key_pem = tls_private_key.example.private_key_pem
  subject {
    common_name  = "example.com"
    organization = "Example Org"
  }
  validity_period_hours = 12
  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
}

module "lb-http" {
  source  = "GoogleCloudPlatform/lb-http/google//modules/serverless_negs"
  version = "~> 12.0"

  project = var.project_id
  name    = "global-app-lb"
  ssl     = true
  ssl_certificates = [google_compute_ssl_certificate.example.self_link]
  https_redirect   = true
  
  backends = {
    default = {
      description = "Serverless NEGs routing to multi-regional Cloud Run"
      groups = [
        for neg in google_compute_region_network_endpoint_group.serverless_neg : {
          group = neg.id
        }
      ]
      enable_cdn                      = false
      timeout_sec                     = 600
      connection_draining_timeout_sec = 600
      
      log_config = {
        enable      = true
        sample_rate = 1.0
      }
    }
  }
}

# ==============================================================================
# 6. LOG EXPORT & BIGQUERY (SECURITY: CMEK & RESTRICTED ACCESS)
# ==============================================================================
resource "google_kms_key_ring" "keyring" {
  name     = "app-keyring-${random_string.suffix.result}"
  location = "us-central1"
  project  = var.project_id
}

resource "google_kms_crypto_key" "bq_key" {
  name            = "bq-key"
  key_ring        = google_kms_key_ring.keyring.id
  purpose         = "ENCRYPT_DECRYPT"
  version_template {
    protection_level = "HSM"
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }
}

resource "google_project_iam_member" "bq_kms_binding" {
  project = var.project_id
  role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-bigquery.iam.gserviceaccount.com"
}

data "google_project" "project" {
  project_id = var.project_id
}

module "log_export" {
  source                 = "terraform-google-modules/log-export/google"
  version                = "~> 11.0"
  destination_uri        = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${local.dataset_id}"
  filter                 = "severity >= ERROR"
  log_sink_name          = "storage_example_logsink"
  parent_resource_id     = var.project_id
  parent_resource_type   = "project"
  unique_writer_identity = true
}

resource "google_bigquery_dataset" "dataset" {
  project                     = var.project_id
  dataset_id                  = local.dataset_id
  friendly_name               = "Org Logs Dataset"
  description                 = "Dataset for organization logs"
  location                    = "us-central1"
  delete_contents_on_destroy  = true
  max_time_travel_hours       = 168 # 7 days reliability

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.bq_key.id
  }

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }
  access {
    role          = "WRITER"
    user_by_email = module.log_export.writer_identity
  }
}
