output "topic_arn" {
  description = "ARN del topic SNS de resúmenes."
  value       = aws_sns_topic.summary.arn
}

output "topic_name" {
  description = "Nombre del topic SNS de resúmenes."
  value       = aws_sns_topic.summary.name
}
