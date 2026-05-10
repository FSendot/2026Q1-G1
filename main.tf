provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# AWS Academy expone un rol pre-creado (LabRole). Esta data source lo
# resuelve para reutilizarlo como task_role y execution_role en ECS,
# evitando crear nuevos roles IAM (restricción del sandbox).
data "aws_iam_role" "lab" {
  name = "LabRole"
}

locals {
  project         = "itba-tp-fraud"
  vpc_cidr        = "10.0.0.0/16"
  onprem_vpc_cidr = "192.168.0.0/16"

  common_tags = {
    Project   = local.project
    ManagedBy = "terraform"
  }

  # Primeras dos AZs de la región (orden estable, conocido en plan) para
  # evitar count/for_each que dependan de random_shuffle.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "network" {
  source = "./modules/network"

  project  = local.project
  vpc_cidr = local.vpc_cidr
  azs      = local.azs
  tags     = local.common_tags
}

# Cuando la simulación on-premise está activa, la cola sólo acepta
# SendMessage desde el CIDR on-premise (vía aws:VpcSourceIp).
module "queue" {
  source = "./modules/queue"

  project         = local.project
  principal_arn   = data.aws_iam_role.lab.arn
  onprem_vpc_cidr = var.enable_onprem_sim ? local.onprem_vpc_cidr : ""
  tags            = local.common_tags
}

module "data_store" {
  source = "./modules/data_store"

  project = local.project
  tags    = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  project = local.project
  tags    = local.common_tags

  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  endpoint_security_group_id = module.network.endpoint_security_group_id

  task_role_arn      = data.aws_iam_role.lab.arn
  execution_role_arn = data.aws_iam_role.lab.arn

  image_uri     = var.image_uri
  task_cpu      = var.task_cpu
  task_memory   = var.task_memory
  desired_count = var.desired_count
  min_capacity  = var.min_capacity
  max_capacity  = var.max_capacity

  queue_arn  = module.queue.queue_arn
  queue_url  = module.queue.queue_url
  queue_name = module.queue.queue_name
  table_name = module.data_store.table_name
}

# Simulación de un sitio on-premise: una VPC aparte con un EC2 strongSwan
# que actúa de router IPsec, junto con el Customer Gateway y la conexión
# Site-to-Site VPN contra el VGW que provee el módulo network.
module "onprem_sim" {
  source = "./modules/onprem_sim"
  count  = var.enable_onprem_sim ? 1 : 0

  project                                = local.project
  azs                                    = local.azs
  vpn_gateway_id                         = module.network.vpn_gateway_id
  aws_vpc_cidr                           = module.network.vpc_cidr
  onprem_vpc_cidr                        = local.onprem_vpc_cidr
  sqs_vpce_eni_count                     = length(local.azs)
  sqs_vpc_endpoint_network_interface_ids = module.network.sqs_vpc_endpoint_network_interface_ids
  tags                                   = local.common_tags
}
