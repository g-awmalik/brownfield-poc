provider "google" {
  project = "mishrarishabh-sbd-1"
}

# ==============================================================================
# 1. IAM & SERVICE ACCOUNTS
# ==============================================================================
module "service_account" {
  source  = "github.com/terraform-google-modules/terraform-google-service-accounts"

  project_id   = "mishrarishabh-sbd-1"
  names        = ["app-cloudrun-sa"]
  display_name = "Cloud Run App Service Account"
  description  = "Identity for Cloud Run to access Spanner"
}

# ==============================================================================
# 2. MULTI-REGIONAL SPANNER INSTANCE
# ==============================================================================
module "spanner" {
  source = "github.com/GoogleCloudPlatform/terraform-google-cloud-spanner"

  project_id            = "mishrarishabh-sbd-1"
  instance_name         = "multi-region-app-db"
  instance_config       = "nam3"
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
      enable_backup            = false
      create_db                = true
    }
  }
}

# ==============================================================================
# 3. MULTI-REGIONAL CLOUD RUN SERVICES (INTERNAL + LB ACCESS)
# ==============================================================================
module "cloud_run_central" {
  source = "github.com/GoogleCloudPlatform/terraform-google-cloud-run//modules/v2"

  project_id             = "mishrarishabh-sbd-1"
  location               = "us-central1"
  service_name           = "app-service-us-central1"
  create_service_account = false
  service_account        = module.service_account.email
  ingress                = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  members = ["allUsers"]

  containers = [
    {
      container_image = "gcr.io/cloudrun/hello"
      env_vars = {
        SPANNER_PROJECT_ID  = "mishrarishabh-sbd-1"
        SPANNER_INSTANCE_ID = element(split("/", module.spanner.spanner_instance_id), 3)
        SPANNER_DATABASE_ID = "app-database"
      }
    }
  ]
}

module "cloud_run_east" {
  source = "github.com/GoogleCloudPlatform/terraform-google-cloud-run//modules/v2"

  project_id             = "mishrarishabh-sbd-1"
  location               = "us-east1"
  service_name           = "app-service-us-east1"
  create_service_account = false
  service_account        = module.service_account.email
  ingress                = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  members = ["allUsers"]

  containers = [
    {
      container_image = "gcr.io/cloudrun/hello"
      env_vars = {
        SPANNER_PROJECT_ID  = "mishrarishabh-sbd-1"
        SPANNER_INSTANCE_ID = element(split("/", module.spanner.spanner_instance_id), 3)
        SPANNER_DATABASE_ID = "app-database"
      }
    }
  ]
}

# ==============================================================================
# 4. GLOBAL LOAD BALANCER FRONTING CLOUD RUN
# ==============================================================================
module "lb-http" {
  source  = "github.com/GoogleCloudPlatform/terraform-google-lb-http//modules/serverless_negs"

  project = "mishrarishabh-sbd-1"
  name    = "global-app-lb"

  ssl                             = true
  managed_ssl_certificate_domains = ["app.example.com"]
  https_redirect                  = true

  backends = {
    default = {
      description = "Serverless NEGs routing to multi-regional Cloud Run"
      groups = []
      serverless_neg_backends = [
        {
          region = "us-central1"
          type   = "cloud-run"
          service = {
            name = module.cloud_run_central.service_name
          }
        },
        {
          region = "us-east1"
          type   = "cloud-run"
          service = {
            name = module.cloud_run_east.service_name
          }
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
