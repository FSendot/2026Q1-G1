output "lambda_function_name" {
  description = "Nombre de la Lambda summarizer."
  value       = aws_lambda_function.summarizer.function_name
}

output "lambda_security_group_id" {
  description = "ID del Security Group de la Lambda summarizer."
  value       = aws_security_group.summarizer.id
}

output "schedule_name" {
  description = "Nombre de la regla EventBridge que ejecuta la Lambda summarizer."
  value       = aws_cloudwatch_event_rule.schedule.name
}
