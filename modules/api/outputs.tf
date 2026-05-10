output "api_endpoint" {
  description = "URL base del HTTP API Gateway para el dashboard (e.g. https://<id>.execute-api.<region>.amazonaws.com)."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "api_id" {
  description = "ID del HTTP API Gateway."
  value       = aws_apigatewayv2_api.main.id
}

output "lambda_function_name" {
  description = "Nombre de la Lambda que sirve el dashboard API."
  value       = aws_lambda_function.api.function_name
}

output "lambda_function_arn" {
  description = "ARN de la Lambda API."
  value       = aws_lambda_function.api.arn
}

output "lambda_security_group_id" {
  description = "ID del Security Group de la Lambda API; expuesto para que la composición raíz agregue la regla de egress hacia RDS."
  value       = aws_security_group.api_lambda.id
}

output "log_group_name" {
  description = "Nombre del CloudWatch Log Group de la Lambda API."
  value       = aws_cloudwatch_log_group.api_lambda.name
}
