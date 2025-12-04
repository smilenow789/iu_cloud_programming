output "cloud_run_url" {
  description = "URL des Backends für die Unity App"
  value       = google_cloud_run_v2_service.backend.uri
}

output "storage_bucket" {
  description = "Name des PDF Upload Buckets"
  value       = google_storage_bucket.pdf_bucket.name
}