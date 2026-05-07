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

# Selecciona dos zonas de disponibilidad al azar entre las disponibles
# en la región. Una vez aplicado, el resultado queda fijo en el state.
resource "random_shuffle" "azs" {
  input        = data.aws_availability_zones.available.names
  result_count = 2
}

locals {
  project  = "itba-tp-fraud"
  vpc_cidr = "10.0.0.0/16"

  common_tags = {
    Project   = local.project
    ManagedBy = "terraform"
  }

  azs = random_shuffle.azs.result
}

module "network" {
  source = "./modules/network"

  project  = local.project
  vpc_cidr = local.vpc_cidr
  azs      = local.azs
  tags     = local.common_tags
}
