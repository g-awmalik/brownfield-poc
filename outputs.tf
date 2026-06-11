output "cloud_run_service_urls" {
  description = "The URIs of the Cloud Run services"
  value = {
    us-central1 = module.cloud_run_central.service_uri
    us-east1    = module.cloud_run_east.service_uri
  }
}

output "spanner_instance_id" {
  description = "The ID of the created Spanner instance"
  value       = module.spanner.spanner_instance_id
}

output "load_balancer_ip" {
  description = "The external IP assigned to the global load balancer"
  value       = module.lb-http.external_ip
}
