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

output "ecs_cluster_name" {
  description = "Nombre del ECS Cluster."
  value       = module.compute.cluster_name
}

output "ecs_service_name" {
  description = "Nombre del ECS Service que ejecuta las tasks Fargate."
  value       = module.compute.service_name
}

output "ecr_repository_url" {
  description = "URL del repositorio ECR donde se publica la imagen del scoring engine."
  value       = module.compute.ecr_repository_url
}

output "log_group_name" {
  description = "Nombre del CloudWatch Log Group del contenedor."
  value       = module.compute.log_group_name
}

output "onprem_vpc_id" {
  description = "Identificador de la VPC simulada de on-premise (null si enable_onprem_sim = false)."
  value       = try(module.onprem_sim[0].onprem_vpc_id, null)
}

output "onprem_vpc_cidr" {
  description = "Bloque CIDR de la VPC simulada de on-premise (null si enable_onprem_sim = false)."
  value       = try(module.onprem_sim[0].onprem_vpc_cidr, null)
}

output "onprem_public_subnet_id" {
  description = "ID de la subnet pública on-premise donde corre el EC2 strongSwan (null si enable_onprem_sim = false)."
  value       = try(module.onprem_sim[0].onprem_public_subnet_id, null)
}

output "vpn_gateway_public_ip" {
  description = "EIP pública del router strongSwan, también usada como ip_address del Customer Gateway (null si enable_onprem_sim = false)."
  value       = try(module.onprem_sim[0].vpn_gateway_public_ip, null)
}

output "customer_gateway_id" {
  description = "ID del Customer Gateway que apunta al router strongSwan (null si enable_onprem_sim = false)."
  value       = try(module.onprem_sim[0].customer_gateway_id, null)
}

output "vpn_connection_id" {
  description = "ID de la conexión Site-to-Site VPN entre el VGW y el Customer Gateway (null si enable_onprem_sim = false)."
  value       = try(module.onprem_sim[0].vpn_connection_id, null)
}
