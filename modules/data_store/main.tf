locals {
  module_tags = merge(var.tags, {
    Component = "data-store"
  })

  table_name = format("%s-user-behavior", var.project)
}

resource "aws_dynamodb_table" "user_behavior" {
  # checkov:skip=CKV_AWS_119: AWS Academy no permite crear KMS CMK; SSE con clave AWS-owned cumple el requisito de cifrado.
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.hash_key_name

  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = var.hash_key_name
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(local.module_tags, {
    Name = local.table_name
  })
}
