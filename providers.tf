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
