output "website_url" {
  description = "URL del sitio web estático del dashboard (S3 website endpoint)."
  value       = "http://${aws_s3_bucket_website_configuration.dashboard.website_endpoint}"
}

output "bucket_name" {
  description = "Nombre del bucket S3 que aloja el dashboard."
  value       = aws_s3_bucket.dashboard.id
}
