locals {
  module_tags = merge(var.tags, {
    Component = "dashboard"
  })

  bucket_name = format("%s-dashboard", var.project)
}

resource "aws_s3_bucket" "dashboard" {
  # checkov:skip=CKV_AWS_18: Access logging deshabilitado en lab académico.
  # checkov:skip=CKV_AWS_52: Versionado deshabilitado; el dashboard son archivos estáticos regenerados por Terraform.
  # checkov:skip=CKV2_AWS_62: Sin notificaciones de eventos S3 (lab).
  # checkov:skip=CKV2_AWS_61: Sin lifecycle configuration (lab).
  # checkov:skip=CKV_AWS_144: Sin replicación S3 (lab).
  bucket        = local.bucket_name
  force_destroy = true

  tags = merge(local.module_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  # checkov:skip=CKV2_AWS_6: Acceso público requerido para sitio web estático.
  bucket = aws_s3_bucket.dashboard.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.dashboard]
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "index.html"
  source       = "${path.root}/app/dashboard/index.html"
  source_hash  = filemd5("${path.root}/app/dashboard/index.html")
  content_type = "text/html"

  tags = local.module_tags
}

resource "aws_s3_object" "app_js" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "app.js"
  source       = "${path.root}/app/dashboard/app.js"
  source_hash  = filemd5("${path.root}/app/dashboard/app.js")
  content_type = "application/javascript"

  tags = local.module_tags
}

resource "aws_s3_object" "config_js" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "config.js"
  content      = templatefile("${path.module}/config.js.tpl", { api_endpoint = var.api_endpoint })
  content_type = "application/javascript"

  tags = local.module_tags
}
