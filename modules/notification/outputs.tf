output "topic_arn" {
  description = "ARN del topic SNS de resúmenes de fraude."
  value       = module.topic.topic_arn
}

output "topic_name" {
  description = "Nombre del topic SNS de resúmenes de fraude."
  value       = module.topic.topic_name
}

output "fraud_alert_queue_url" {
  description = "URL de la cola SQS donde el processor encola transacciones fraudulentas para resumen."
  value       = module.summary_queue.queue_url
}

output "fraud_alert_queue_arn" {
  description = "ARN de la cola SQS de alertas de fraude."
  value       = module.summary_queue.queue_arn
}

output "fraud_alert_queue_name" {
  description = "Nombre de la cola SQS de alertas de fraude."
  value       = module.summary_queue.queue_name
}

output "fraud_alert_dlq_arn" {
  description = "ARN del DLQ de la cola SQS de alertas de fraude."
  value       = module.summary_queue.dlq_arn
}

output "summarizer_lambda_function_name" {
  description = "Nombre de la Lambda que resume alertas de fraude y publica en SNS."
  value       = module.summarizer.lambda_function_name
}

output "summarizer_security_group_id" {
  description = "ID del Security Group usado por la Lambda summarizer."
  value       = module.summarizer.lambda_security_group_id
}

output "summarizer_schedule_name" {
  description = "Nombre de la regla EventBridge que ejecuta la Lambda summarizer."
  value       = module.summarizer.schedule_name
}
