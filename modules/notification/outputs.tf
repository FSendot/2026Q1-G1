output "topic_arn" {
  description = "ARN del topic SNS de resultados de fraude."
  value       = aws_sns_topic.results.arn
}

output "topic_name" {
  description = "Nombre del topic SNS de resultados de fraude."
  value       = aws_sns_topic.results.name
}
