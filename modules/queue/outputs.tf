output "queue_url" {
  description = "URL de la cola principal de transacciones."
  value       = aws_sqs_queue.main.url
}

output "queue_arn" {
  description = "ARN de la cola principal de transacciones."
  value       = aws_sqs_queue.main.arn
}

output "queue_name" {
  description = "Nombre de la cola principal de transacciones."
  value       = aws_sqs_queue.main.name
}

output "dlq_url" {
  description = "URL del Dead Letter Queue."
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = "ARN del Dead Letter Queue."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Nombre del Dead Letter Queue."
  value       = aws_sqs_queue.dlq.name
}
