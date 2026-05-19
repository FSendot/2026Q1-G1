output "vpc_id" {
  description = "Identificador de la VPC creada por el módulo."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Bloque CIDR principal de la VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Lista de IDs de las subnets privadas, una por AZ."
  value       = module.vpc.private_subnets
}

output "private_route_table_ids" {
  description = "IDs de las route tables asociadas a las subnets privadas."
  value       = module.vpc.private_route_table_ids
}

output "endpoint_security_group_id" {
  description = "ID del Security Group asociado a los Interface VPC Endpoints; los clientes deben permitir egress hacia este SG."
  value       = aws_security_group.endpoints.id
}

output "vpn_gateway_id" {
  description = "ID del Virtual Private Gateway adjuntado a la VPC, listo para enlazar con un futuro Customer Gateway."
  value       = module.vpc.vgw_id
}

output "interface_endpoint_ids" {
  description = "Mapa de Interface VPC Endpoints provisionados, indexado por servicio (sqs, ecr_api, ecr_dkr, logs, sns, secretsmanager, cognito_idp)."
  value = merge(
    { for k, v in aws_vpc_endpoint.interface : k => v.id },
    { cognito_idp = aws_vpc_endpoint.cognito_idp.id },
  )
}

output "cognito_idp_subnet_ids" {
  description = "Subnets privadas donde se desplegó el VPC endpoint cognito-idp (solo AZs soportadas por el servicio)."
  value       = local.cognito_idp_subnet_ids
}

output "sqs_vpc_endpoint_network_interface_ids" {
  description = "IDs de las ENIs del Interface VPC Endpoint de SQS (una por subnet privada)."
  value       = tolist(aws_vpc_endpoint.interface["sqs"].network_interface_ids)
}

output "gateway_endpoint_ids" {
  description = "Mapa de Gateway VPC Endpoints provisionados, indexado por servicio (s3, dynamodb)."
  value       = { for k, v in aws_vpc_endpoint.gateway : k => v.id }
}
