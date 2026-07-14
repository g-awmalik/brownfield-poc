resource "google_storage_bucket" "static-site" {
  name          = "image-store-com-static-site-avikuma-dev-04"
  location      = "EU"
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }

  cors {
    origin          = ["http://image-store.com"]
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }

  logging {
    log_bucket = google_storage_bucket.log_bucket.name
    log_object_prefix = "gcs-log"
  }

  public_access_prevention = "inherited"

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 5
      with_state = "ARCHIVED"
    }
  }
}

resource "google_storage_bucket" "log_bucket" {
  name                        = "image-store-com-logs-avikuma-dev-04"
  location                    = "EU"
  uniform_bucket_level_access = true
  force_destroy               = true
}
