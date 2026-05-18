output "website_url" {
  description = "URL del sitio web estático del dashboard (S3 website endpoint)."
  value       = "http://${aws_s3_bucket_website_configuration.dashboard.website_endpoint}"
}

output "https_index_url" {
  description = "URL HTTPS del objeto index.html del dashboard, apta como callback/logout de Cognito."
  value       = "https://${aws_s3_bucket.dashboard.id}.s3.${data.aws_region.current.name}.amazonaws.com/index.html"
}

output "bucket_name" {
  description = "Nombre del bucket S3 que aloja el dashboard."
  value       = aws_s3_bucket.dashboard.id
}
