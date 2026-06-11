terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 3.53.0"
    }
  }
}

provider "google" {
  project = "mishrarishabh-sbd-1"
}

module "service_account" {
  source       = "github.com/terraform-google-modules/terraform-google-service-accounts"
  project_id   = "mishrarishabh-sbd-1"
  names        = ["app-cloudrun-sa"]
  display_name = "Cloud Run App Service Account"
  description  = "Identity for Cloud Run to access Spanner"
}

module "spanner" {
  source = "github.com/GoogleCloudPlatform/terraform-google-cloud-spanner"

  project_id            = "mishrarishabh-sbd-1"
  instance_name         = "regional-app-db"
  instance_config       = "regional-us-central1"
  instance_display_name = "Regional Application Spanner"
  instance_size = {
    num_nodes = 1
  }
  database_config = {
    "app-database" = {
      version_retention_period = "3d"
      ddl                      = []
      deletion_protection      = false
      enable_backup            = false
      create_db                = true
      database_iam             = [
        "serviceAccount:app-cloudrun-sa@mishrarishabh-sbd-1.iam.gserviceaccount.com=>roles/spanner.databaseUser"
      ]
    }
  }
}

module "cloud_run_us_central1" {
  source = "github.com/GoogleCloudPlatform/terraform-google-cloud-run//modules/v2"

  project_id             = "mishrarishabh-sbd-1"
  location               = "us-central1"
  service_name           = "app-service-us-central1"
  create_service_account = false
  service_account        = "app-cloudrun-sa@mishrarishabh-sbd-1.iam.gserviceaccount.com"
  
  # Remediating the public ingress to internal + load balancing for better security
  ingress                = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  containers = [
    {
      container_image = "gcr.io/cloudrun/hello"
      env_vars = {
        SPANNER_PROJECT_ID  = "mishrarishabh-sbd-1"
        SPANNER_INSTANCE_ID = "regional-app-db"
        SPANNER_DATABASE_ID = "app-database"
      }
    }
  ]
}

module "cloud_run_us_east1" {
  source = "github.com/GoogleCloudPlatform/terraform-google-cloud-run//modules/v2"

  project_id             = "mishrarishabh-sbd-1"
  location               = "us-east1"
  service_name           = "app-service-us-east1"
  create_service_account = false
  service_account        = "app-cloudrun-sa@mishrarishabh-sbd-1.iam.gserviceaccount.com"
  
  # Remediating the public ingress to internal + load balancing for better security
  ingress                = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  containers = [
    {
      container_image = "gcr.io/cloudrun/hello"
      env_vars = {
        SPANNER_PROJECT_ID  = "mishrarishabh-sbd-1"
        SPANNER_INSTANCE_ID = "regional-app-db"
        SPANNER_DATABASE_ID = "app-database"
      }
    }
  ]
}

