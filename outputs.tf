output "vpc_id" {
  description = "Identificador de la VPC privada que aloja el motor de scoring."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Bloque CIDR principal de la VPC."
  value       = module.network.vpc_cidr
}

output "private_subnet_ids" {
  description = "IDs de las subnets privadas donde se despliegan las tasks de Fargate."
  value       = module.network.private_subnet_ids
}

output "endpoint_security_group_id" {
  description = "ID del Security Group asociado a los Interface VPC Endpoints; los SG de las tasks deben permitir egress hacia él."
  value       = module.network.endpoint_security_group_id
}

output "vpn_gateway_id" {
  description = "ID del Virtual Private Gateway adjuntado a la VPC, listo para enlazar con un futuro Customer Gateway."
  value       = module.network.vpn_gateway_id
}

output "queue_url" {
  description = "URL de la cola principal de transacciones."
  value       = module.queue.queue_url
}

output "queue_arn" {
  description = "ARN de la cola principal de transacciones."
  value       = module.queue.queue_arn
}

output "dlq_arn" {
  description = "ARN del Dead Letter Queue."
  value       = module.queue.dlq_arn
}

output "user_behavior_table_name" {
  description = "Nombre de la tabla DynamoDB que persiste el comportamiento histórico de usuarios."
  value       = module.data_store.table_name
}

output "user_behavior_table_arn" {
  description = "ARN de la tabla DynamoDB que persiste el comportamiento histórico de usuarios."
  value       = module.data_store.table_arn
}
