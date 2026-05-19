output "onprem_vpc_id" {
  description = "Identificador de la VPC simulada de on-premise."
  value       = aws_vpc.onprem.id
}

output "onprem_vpc_cidr" {
  description = "Bloque CIDR de la VPC simulada de on-premise."
  value       = aws_vpc.onprem.cidr_block
}

output "onprem_public_subnet_id" {
  description = "ID de la subnet pública on-premise donde se aloja el EC2 strongSwan."
  value       = aws_subnet.public.id
}

output "vpn_gateway_public_ip" {
  description = "Dirección IP pública (EIP) del EC2 strongSwan; coincide con el ip_address del Customer Gateway."
  value       = aws_eip.gw.public_ip
}

output "customer_gateway_id" {
  description = "ID del Customer Gateway que apunta a la EIP del router strongSwan."
  value       = aws_customer_gateway.cgw.id
}

output "vpn_connection_id" {
  description = "ID de la conexión Site-to-Site VPN entre el VGW del lado AWS y el Customer Gateway on-premise."
  value       = aws_vpn_connection.vpn.id
}

output "cloudformation_stack_id" {
  description = "ID del stack de CloudFormation que despliega el VPN gateway strongSwan."
  value       = aws_cloudformation_stack.strongswan.id
}

output "traffic_producer_instance_ids" {
  description = "Mapa de IDs de instancia EC2 para los productores de tráfico on-premise simulado (vacío si enable_traffic_producers = false)."
  value       = { for key, instance in aws_instance.producer : key => instance.id }
}

output "traffic_producer_private_ips" {
  description = "Mapa de IPs privadas de los productores de tráfico on-premise simulado (vacío si enable_traffic_producers = false)."
  value       = { for key, instance in aws_instance.producer : key => instance.private_ip }
}
