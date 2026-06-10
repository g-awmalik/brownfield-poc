# Create a dedicated service account for the VM
resource "google_service_account" "vm_sa" {
  account_id   = "terraform-test-vm-sa"
  display_name = "Service Account for Terraform Test VM"
}

resource "google_compute_instance" "vm" {
  name         = "terraform-test-vm"
  machine_type = "e2-small"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    network = "default"
  }

  # Attach the service account to the VM
  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}