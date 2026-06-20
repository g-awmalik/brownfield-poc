variable "project_id" {
  description = "The GCP Project ID"
  type        = string
  default     = "mishrarishabh-sbd-1"
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

variable "container_image" {
  description = "The container image to deploy to Cloud Run"
  type        = string
  default     = "gcr.io/cloudrun/hello"
}
