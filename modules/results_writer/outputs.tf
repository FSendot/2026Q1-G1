output "queue_arn" {
  description = "ARN de la cola SQS de resultados."
  value       = aws_sqs_queue.results.arn
}

output "queue_url" {
  description = "URL de la cola SQS de resultados."
  value       = aws_sqs_queue.results.url
}

output "queue_name" {
  description = "Nombre de la cola SQS de resultados."
  value       = aws_sqs_queue.results.name
}

output "dlq_arn" {
  description = "ARN del Dead Letter Queue de la cola de resultados."
  value       = aws_sqs_queue.results_dlq.arn
}

output "lambda_function_name" {
  description = "Nombre de la Lambda que escribe resultados en RDS."
  value       = aws_lambda_function.writer.function_name
}

output "lambda_function_arn" {
  description = "ARN de la Lambda results-writer."
  value       = aws_lambda_function.writer.arn
}

output "lambda_security_group_id" {
  description = "ID del Security Group de la Lambda results-writer; expuesto para que la composición raíz agregue la regla de egress hacia RDS."
  value       = aws_security_group.writer_lambda.id
}

output "log_group_name" {
  description = "Nombre del CloudWatch Log Group de la Lambda."
  value       = aws_cloudwatch_log_group.writer.name
}
