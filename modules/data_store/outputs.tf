output "table_name" {
  description = "Nombre de la tabla DynamoDB que persiste el comportamiento histórico de usuarios."
  value       = aws_dynamodb_table.user_behavior.name
}

output "table_arn" {
  description = "ARN de la tabla DynamoDB que persiste el comportamiento histórico de usuarios."
  value       = aws_dynamodb_table.user_behavior.arn
}

output "table_id" {
  description = "Identificador interno (id) de la tabla DynamoDB."
  value       = aws_dynamodb_table.user_behavior.id
}

output "hash_key_name" {
  description = "Nombre del atributo hash key configurado en la tabla."
  value       = var.hash_key_name
}
