output "user_pool_id" {
  description = "ID del Cognito User Pool."
  value       = aws_cognito_user_pool.this.id
}

output "client_id" {
  description = "ID del app client público de Cognito."
  value       = aws_cognito_user_pool_client.this.id
}

output "domain_url" {
  description = "URL del dominio administrado de Cognito."
  value       = local.domain_url
}

output "hosted_ui_base_url" {
  description = "URL base del Hosted UI de Cognito."
  value       = local.hosted_ui_base_url
}

output "issuer" {
  description = "Issuer del JWT de Cognito."
  value       = local.issuer
}
