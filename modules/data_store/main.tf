locals {
  module_tags = merge(var.tags, {
    Component = "data-store"
  })

  table_name    = format("%s-user-behavior", var.project)
  db_identifier = format("%s-results-db", var.project)
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

resource "aws_db_subnet_group" "results" {
  name       = format("%s-results-db-subnet-group", var.project)
  subnet_ids = var.private_subnet_ids

  tags = merge(local.module_tags, {
    Name = format("%s-results-db-subnet-group", var.project)
  })
}

resource "aws_security_group" "rds" {
  name        = format("%s-rds-sg", var.project)
  description = "RDS PostgreSQL; ingress TCP/5432 desde Lambdas en VPC. Las reglas de ingress se definen en la composicion raiz para evitar dependencias circulares entre modulos."
  vpc_id      = var.vpc_id

  tags = merge(local.module_tags, {
    Name = format("%s-rds-sg", var.project)
  })
}

resource "aws_db_instance" "results" {
  # checkov:skip=CKV_AWS_157: Multi-AZ deshabilitado para reducir costo en lab académico.
  # checkov:skip=CKV_AWS_133: Enhanced Monitoring deshabilitado (lab; requiere rol IAM extra no disponible en Academy).
  # checkov:skip=CKV_AWS_118: Performance Insights deshabilitado (lab cost).
  # checkov:skip=CKV_AWS_293: Deletion protection deshabilitado para permitir terraform destroy en lab.
  # checkov:skip=CKV_AWS_129: Backup retention en 0 para reducir costo en lab académico.
  # checkov:skip=CKV_AWS_354: Dedicated log exports deshabilitados (lab).

  identifier = local.db_identifier

  engine         = "postgres"
  engine_version = "17.4"
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.results.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                = false
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  lifecycle {
    ignore_changes = [password]
  }

  tags = merge(local.module_tags, {
    Name = local.db_identifier
  })
}
