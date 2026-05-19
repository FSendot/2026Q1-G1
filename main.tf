provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

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

  dashboard_app_url       = format("https://%s-dashboard-%s.s3.%s.amazonaws.com/index.html", local.project, data.aws_caller_identity.current.account_id, data.aws_region.current.name)
  dashboard_callback_urls = [local.dashboard_app_url, "http://localhost:3000/"]
  dashboard_logout_urls   = [local.dashboard_app_url, "http://localhost:3000/"]
}

module "network" {
  source = "./modules/network"

  project  = local.project
  vpc_cidr = local.vpc_cidr
  azs      = local.azs
  tags     = local.common_tags
}

# Cuando la simulación on-premise está activa, la cola sólo acepta
# SendMessage desde la VPC on-premise (vía aws:SourceVpc), que funciona
# tanto para tráfico intra-VPC como cross-VPC via VPN.
module "queue" {
  source = "./modules/queue"

  project         = local.project
  principal_arn   = data.aws_iam_role.lab.arn
  onprem_vpc_cidr = var.enable_onprem_sim ? local.onprem_vpc_cidr : ""
  onprem_vpc_id   = var.enable_onprem_sim ? module.network.vpc_id : ""
  tags            = local.common_tags
}

module "data_store" {
  source = "./modules/data_store"

  project            = local.project
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  db_password        = random_password.db.result
  principal_arn      = data.aws_iam_role.lab.arn
  tags               = local.common_tags
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

  processor_concurrency = var.processor_concurrency
  processor_pollers     = var.processor_pollers

  queue_arn             = module.queue.queue_arn
  queue_url             = module.queue.queue_url
  queue_name            = module.queue.queue_name
  table_name            = module.data_store.table_name
  results_queue_url     = module.results_writer.queue_url
  fraud_alert_queue_url = module.notification.fraud_alert_queue_url
  audit_bucket_name     = module.data_store.audit_bucket_name
}

resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_lambda_layer_version" "psycopg2" {
  filename                 = "layers/psycopg2/psycopg2-layer.zip"
  layer_name               = format("%s-psycopg2", local.project)
  source_code_hash         = filebase64sha256("layers/psycopg2/psycopg2-layer.zip")
  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["x86_64"]

  lifecycle {
    create_before_destroy = true
  }
}

module "notification" {
  source = "./modules/notification"

  project                    = local.project
  principal_arn              = data.aws_iam_role.lab.arn
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  endpoint_security_group_id = module.network.endpoint_security_group_id
  summarizer_source_file     = "${path.module}/app/notification/summarizer/handler.py"
  summary_interval_minutes   = var.fraud_alert_summary_interval_minutes
  tags                       = local.common_tags
}

module "results_writer" {
  source = "./modules/results_writer"

  project                     = local.project
  principal_arn               = data.aws_iam_role.lab.arn
  vpc_id                      = module.network.vpc_id
  private_subnet_ids          = module.network.private_subnet_ids
  endpoint_security_group_id  = module.network.endpoint_security_group_id
  db_host                     = module.data_store.proxy_endpoint
  db_port                     = module.data_store.db_port
  db_name                     = module.data_store.db_name
  db_username                 = module.data_store.db_username
  db_password                 = random_password.db.result
  package_file                = "${path.root}/app/results_writer/build/results-writer.zip"
  sqs_batch_size              = var.results_writer_batch_size
  sqs_batching_window_seconds = var.results_writer_batching_window_seconds
  tags                        = local.common_tags
}

module "auth" {
  source = "./modules/auth"

  project                    = local.project
  tags                       = local.common_tags
  callback_urls              = local.dashboard_callback_urls
  logout_urls                = local.dashboard_logout_urls
  google_oauth_client_id     = var.google_oauth_client_id
  google_oauth_client_secret = var.google_oauth_client_secret
}

module "api" {
  source = "./modules/api"

  project                    = local.project
  principal_arn              = data.aws_iam_role.lab.arn
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  endpoint_security_group_id = module.network.endpoint_security_group_id
  psycopg2_layer_arn         = aws_lambda_layer_version.psycopg2.arn
  db_host                    = module.data_store.proxy_endpoint
  db_port                    = module.data_store.db_port
  db_name                    = module.data_store.db_name
  db_username                = module.data_store.db_username
  db_password                = random_password.db.result
  sns_topic_arn              = module.notification.topic_arn
  jwt_issuer                 = module.auth.issuer
  jwt_audience               = module.auth.client_id
  tags                       = local.common_tags
}

module "dashboard" {
  source = "./modules/dashboard"

  project                    = local.project
  api_endpoint               = module.api.api_endpoint
  cognito_user_pool_id       = module.auth.user_pool_id
  cognito_client_id          = module.auth.client_id
  cognito_domain_url         = module.auth.domain_url
  cognito_hosted_ui_base_url = module.auth.hosted_ui_base_url
  cognito_issuer             = module.auth.issuer
  cognito_redirect_uri       = local.dashboard_app_url
  cognito_logout_uri         = local.dashboard_app_url
  tags                       = local.common_tags
}

# Proxy ↔ RDS

resource "aws_vpc_security_group_egress_rule" "proxy_to_rds" {
  security_group_id            = module.data_store.proxy_security_group_id
  description                  = "PostgreSQL desde proxy hacia RDS"
  referenced_security_group_id = module.data_store.rds_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_proxy" {
  security_group_id            = module.data_store.rds_security_group_id
  description                  = "PostgreSQL desde RDS Proxy"
  referenced_security_group_id = module.data_store.proxy_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = local.common_tags
}

# Lambda results-writer ↔ Proxy

resource "aws_vpc_security_group_egress_rule" "writer_lambda_to_proxy" {
  security_group_id            = module.results_writer.lambda_security_group_id
  description                  = "PostgreSQL desde Lambda results-writer hacia RDS Proxy"
  referenced_security_group_id = module.data_store.proxy_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_writer_lambda" {
  security_group_id            = module.data_store.proxy_security_group_id
  description                  = "PostgreSQL desde Lambda results-writer"
  referenced_security_group_id = module.results_writer.lambda_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = local.common_tags
}

# Lambda api ↔ Proxy

resource "aws_vpc_security_group_egress_rule" "api_lambda_to_proxy" {
  security_group_id            = module.api.lambda_security_group_id
  description                  = "PostgreSQL desde Lambda API hacia RDS Proxy"
  referenced_security_group_id = module.data_store.proxy_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_api_lambda" {
  security_group_id            = module.data_store.proxy_security_group_id
  description                  = "PostgreSQL desde Lambda API"
  referenced_security_group_id = module.api.lambda_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = local.common_tags
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
