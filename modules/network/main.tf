data "aws_region" "current" {}

locals {
  module_tags = merge(var.tags, {
    Component = "network"
  })

  interface_endpoint_services = {
    sqs            = "com.amazonaws.${data.aws_region.current.name}.sqs"
    ecr_api        = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
    ecr_dkr        = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
    logs           = "com.amazonaws.${data.aws_region.current.name}.logs"
    sns            = "com.amazonaws.${data.aws_region.current.name}.sns"
    secretsmanager = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  }

  gateway_endpoint_services = toset(["s3", "dynamodb"])

  private_subnet_cidrs = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]
}

module "vpc" {
  # checkov:skip=CKV_TF_1: SemVer pinning permitido por docs/STYLE_GUIDE.md; el pin a commit SHA dificulta upgrades en un módulo oficial firmado por HashiCorp.
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = format("%s-vpc", var.project)
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = local.private_subnet_cidrs
  public_subnets  = []

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = false
  enable_vpn_gateway = true

  propagate_private_route_tables_vgw = true

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  tags = local.module_tags

  private_subnet_tags = {
    Tier = "private"
  }
}

data "aws_vpc_endpoint_service" "cognito_idp" {
  service = "cognito-idp"
}

locals {
  cognito_idp_subnet_ids = [
    for i, az in var.azs : module.vpc.private_subnets[i]
    if contains(data.aws_vpc_endpoint_service.cognito_idp.availability_zones, az)
  ]
}

check "cognito_idp_subnet_coverage" {
  assert {
    condition     = length(local.cognito_idp_subnet_ids) > 0
    error_message = "Ninguna subnet privada está en una AZ que soporte el VPC endpoint cognito-idp. Ajustá var.azs en la composición raíz."
  }
}

resource "aws_security_group" "endpoints" {
  name        = format("%s-endpoints-sg", var.project)
  description = "SG para los Interface VPC Endpoints; permite HTTPS desde la VPC."
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.module_tags, {
    Name = format("%s-endpoints-sg", var.project)
  })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https_from_vpc" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS desde clientes dentro de la VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = local.module_tags
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https_from_additional_cidr" {
  for_each = toset(var.additional_endpoint_client_cidrs)

  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS desde CIDR adicional autorizado"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = local.module_tags
}

resource "aws_vpc_security_group_egress_rule" "endpoints_to_vpc" {
  security_group_id = aws_security_group.endpoints.id
  description       = "Respuestas hacia clientes dentro de la VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"

  tags = local.module_tags
}

resource "aws_vpc_security_group_egress_rule" "endpoints_to_additional_cidr" {
  for_each = toset(var.additional_endpoint_client_cidrs)

  security_group_id = aws_security_group.endpoints.id
  description       = "Respuestas hacia CIDR adicional autorizado"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"

  tags = local.module_tags
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = local.gateway_endpoint_services

  vpc_id            = module.vpc.vpc_id
  service_name      = format("com.amazonaws.%s.%s", data.aws_region.current.name, each.key)
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.module_tags, {
    Name = format("%s-vpce-%s", var.project, each.key)
  })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoint_services

  vpc_id              = module.vpc.vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.module_tags, {
    Name = format("%s-vpce-%s", var.project, replace(each.key, "_", "-"))
  })
}

resource "aws_vpc_endpoint" "cognito_idp" {
  vpc_id              = module.vpc.vpc_id
  service_name        = data.aws_vpc_endpoint_service.cognito_idp.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.cognito_idp_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.module_tags, {
    Name = format("%s-vpce-cognito-idp", var.project)
  })
}
