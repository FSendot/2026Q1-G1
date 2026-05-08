locals {
  module_tags = merge(var.tags, {
    Component = "onprem-sim"
  })

  name_prefix = format("%s-onprem", var.project)

  tunnel_psk_secret_names = {
    tunnel1 = format("%s-tunnel1-psk", local.name_prefix)
    tunnel2 = format("%s-tunnel2-psk", local.name_prefix)
  }
}

# -----------------------------------------------------------------------------
# On-premise simulated VPC: minimal, single AZ, public-only.
# -----------------------------------------------------------------------------

resource "aws_vpc" "onprem" {
  # checkov:skip=CKV2_AWS_11: VPC Flow Logs intencionalmente deshabilitados; esta VPC simula on-premise para pruebas de VPN en la cuenta de laboratorio.
  # checkov:skip=CKV2_AWS_12: El Default Security Group queda con sus reglas por defecto; el tráfico real corre por el SG dedicado y por el SG creado dentro del stack CFN.
  cidr_block           = var.onprem_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.module_tags, {
    Name = format("%s-vpc", local.name_prefix)
  })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.onprem.id

  tags = merge(local.module_tags, {
    Name = format("%s-igw", local.name_prefix)
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.onprem.id
  cidr_block              = var.onprem_public_subnet_cidr
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true

  tags = merge(local.module_tags, {
    Name = format("%s-public", local.name_prefix)
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.onprem.id

  tags = merge(local.module_tags, {
    Name = format("%s-public-rt", local.name_prefix)
  })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Permissive SG for the simulated on-prem network. The real EC2 NIC is attached
# to the SG that the embedded CloudFormation stack creates internally; this SG
# is exported for diagnostics and for any future client EC2 dropped on-prem.
resource "aws_security_group" "router" {
  # checkov:skip=CKV_AWS_24: SG simulado con ingreso amplio para IKE/ESP desde Internet, intencional en la simulación de un sitio remoto.
  # checkov:skip=CKV_AWS_260: idem; el tráfico HTTP/HTTPS no se expone, pero IKE/ESP debe ser alcanzable desde el lado AWS.
  # checkov:skip=CKV2_AWS_5: SG diagnóstico no adjuntado; el SG real del EC2 lo crea el stack CFN embebido en aws_cloudformation_stack.strongswan.
  name        = format("%s-router-sg", local.name_prefix)
  description = "SG diagnóstico del router on-premise simulado: permite IKE/ESP/AH desde Internet y todo el tráfico desde la VPC del lado AWS."
  vpc_id      = aws_vpc.onprem.id

  tags = merge(local.module_tags, {
    Name = format("%s-router-sg", local.name_prefix)
  })
}

resource "aws_vpc_security_group_ingress_rule" "router_ike" {
  security_group_id = aws_security_group.router.id
  description       = "IKE (UDP 500) desde Internet para negociación IPsec."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 500
  to_port           = 500

  tags = local.module_tags
}

resource "aws_vpc_security_group_ingress_rule" "router_natt" {
  security_group_id = aws_security_group.router.id
  description       = "NAT-T (UDP 4500) desde Internet para IPsec."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 4500
  to_port           = 4500

  tags = local.module_tags
}

resource "aws_vpc_security_group_ingress_rule" "router_esp" {
  security_group_id = aws_security_group.router.id
  description       = "ESP (IP proto 50) desde Internet."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "50"

  tags = local.module_tags
}

resource "aws_vpc_security_group_ingress_rule" "router_ah" {
  security_group_id = aws_security_group.router.id
  description       = "AH (IP proto 51) desde Internet."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "51"

  tags = local.module_tags
}

resource "aws_vpc_security_group_ingress_rule" "router_from_aws" {
  security_group_id = aws_security_group.router.id
  description       = "Tráfico de retorno desde la VPC del lado AWS a través del túnel."
  cidr_ipv4         = var.aws_vpc_cidr
  ip_protocol       = "-1"

  tags = local.module_tags
}

resource "aws_vpc_security_group_egress_rule" "router_all" {
  security_group_id = aws_security_group.router.id
  description       = "Egress sin restricciones (router on-premise simulado)."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = local.module_tags
}

resource "aws_eip" "gw" {
  # checkov:skip=CKV2_AWS_19: La EIP se asocia al EC2 dentro del stack CFN (rVpnGatewayEipAssociation), no por Terraform; checkov no detecta la dependencia cruzada.
  domain = "vpc"

  tags = merge(local.module_tags, {
    Name = format("%s-router-eip", local.name_prefix)
  })

  depends_on = [aws_internet_gateway.igw]
}

# -----------------------------------------------------------------------------
# AWS-side glue: Customer Gateway + Site-to-Site VPN connection (BGP).
# -----------------------------------------------------------------------------

resource "aws_customer_gateway" "cgw" {
  bgp_asn    = 65000
  ip_address = aws_eip.gw.public_ip
  type       = "ipsec.1"

  tags = merge(local.module_tags, {
    Name = format("%s-cgw", local.name_prefix)
  })
}

resource "aws_vpn_connection" "vpn" {
  customer_gateway_id = aws_customer_gateway.cgw.id
  vpn_gateway_id      = var.vpn_gateway_id
  type                = "ipsec.1"
  static_routes_only  = false

  tags = merge(local.module_tags, {
    Name = format("%s-vpn", local.name_prefix)
  })
}

# -----------------------------------------------------------------------------
# Pre-shared keys delivered to the EC2 via Secrets Manager (the CFN template's
# bootstrap script reads them with `aws secretsmanager get-secret-value`).
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "tunnel1" {
  # checkov:skip=CKV_AWS_149: KMS-CMK no disponible en AWS Academy; se usa la KMS managed key por defecto de Secrets Manager.
  # checkov:skip=CKV2_AWS_57: rotación automática deshabilitada de forma intencional para el laboratorio; los PSKs son efímeros junto con el stack.
  name                    = local.tunnel_psk_secret_names.tunnel1
  description             = "PSK del túnel 1 de la conexión Site-to-Site VPN para el VPN gateway strongSwan."
  recovery_window_in_days = 0

  tags = merge(local.module_tags, {
    Name   = local.tunnel_psk_secret_names.tunnel1
    Tunnel = "1"
  })
}

resource "aws_secretsmanager_secret_version" "tunnel1" {
  secret_id     = aws_secretsmanager_secret.tunnel1.id
  secret_string = jsonencode({ psk = aws_vpn_connection.vpn.tunnel1_preshared_key })
}

resource "aws_secretsmanager_secret" "tunnel2" {
  # checkov:skip=CKV_AWS_149: idem tunnel1; no hay KMS CMK disponible en el sandbox de AWS Academy.
  # checkov:skip=CKV2_AWS_57: idem tunnel1.
  name                    = local.tunnel_psk_secret_names.tunnel2
  description             = "PSK del túnel 2 de la conexión Site-to-Site VPN para el VPN gateway strongSwan."
  recovery_window_in_days = 0

  tags = merge(local.module_tags, {
    Name   = local.tunnel_psk_secret_names.tunnel2
    Tunnel = "2"
  })
}

resource "aws_secretsmanager_secret_version" "tunnel2" {
  secret_id     = aws_secretsmanager_secret.tunnel2.id
  secret_string = jsonencode({ psk = aws_vpn_connection.vpn.tunnel2_preshared_key })
}

# -----------------------------------------------------------------------------
# strongSwan EC2 deployed by embedding the existing CloudFormation template.
# Tunnel inside IPs are passed with /30 to satisfy the template's CIDR pattern.
# -----------------------------------------------------------------------------

resource "aws_cloudformation_stack" "strongswan" {
  name          = format("%s-strongswan", local.name_prefix)
  template_body = file("${path.module}/../../templates/vpn-gateway-strongswan.yml")
  capabilities  = ["CAPABILITY_IAM"]

  parameters = {
    pOrg        = "itba"
    pSystem     = "tp"
    pApp        = "vpngw"
    pEnvPurpose = "lab"
    pAuthType   = "psk"

    pTunnel1PskSecretName        = aws_secretsmanager_secret.tunnel1.name
    pTunnel1VgwOutsideIpAddress  = aws_vpn_connection.vpn.tunnel1_address
    pTunnel1CgwInsideIpAddress   = format("%s/30", aws_vpn_connection.vpn.tunnel1_cgw_inside_address)
    pTunnel1VgwInsideIpAddress   = format("%s/30", aws_vpn_connection.vpn.tunnel1_vgw_inside_address)
    pTunnel1VgwBgpAsn            = tostring(aws_vpn_connection.vpn.tunnel1_bgp_asn)
    pTunnel1BgpNeighborIpAddress = aws_vpn_connection.vpn.tunnel1_vgw_inside_address

    pTunnel2PskSecretName        = aws_secretsmanager_secret.tunnel2.name
    pTunnel2VgwOutsideIpAddress  = aws_vpn_connection.vpn.tunnel2_address
    pTunnel2CgwInsideIpAddress   = format("%s/30", aws_vpn_connection.vpn.tunnel2_cgw_inside_address)
    pTunnel2VgwInsideIpAddress   = format("%s/30", aws_vpn_connection.vpn.tunnel2_vgw_inside_address)
    pTunnel2VgwBgpAsn            = tostring(aws_vpn_connection.vpn.tunnel2_bgp_asn)
    pTunnel2BgpNeighborIpAddress = aws_vpn_connection.vpn.tunnel2_vgw_inside_address

    pLocalBgpAsn     = tostring(aws_customer_gateway.cgw.bgp_asn)
    pUseElasticIp    = "true"
    pEipAllocationId = aws_eip.gw.id
    pVpcId           = aws_vpc.onprem.id
    pVpcCidr         = aws_vpc.onprem.cidr_block
    pSubnetId        = aws_subnet.public.id
    pInstanceType    = var.instance_type
  }

  tags = merge(local.module_tags, {
    Name = format("%s-strongswan", local.name_prefix)
  })

  lifecycle {
    # `pAmiId` es un AWS::SSM::Parameter::Value que CloudFormation resuelve
    # en cada update; ignorarlo evita un diff perpetuo cuando AWS rota la AMI.
    ignore_changes = [parameters["pAmiId"]]
  }

  depends_on = [
    aws_secretsmanager_secret_version.tunnel1,
    aws_secretsmanager_secret_version.tunnel2,
    aws_route_table_association.public,
    aws_vpn_connection.vpn,
  ]
}
