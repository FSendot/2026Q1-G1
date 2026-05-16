data "aws_region" "current" {}

locals {
  module_tags = merge(var.tags, {
    Component = "results-writer"
  })

  queue_name     = format("%s-results-events", var.project)
  dlq_name       = format("%s-results-events-dlq", var.project)
  function_name  = format("%s-results-writer", var.project)
  log_group_name = format("/aws/lambda/%s-results-writer", var.project)
}

resource "aws_sqs_queue" "results_dlq" {
  name = local.dlq_name

  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = merge(local.module_tags, {
    Name = local.dlq_name
    Role = "dlq"
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "results_dlq" {
  queue_url = aws_sqs_queue.results_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.results.arn]
  })
}

resource "aws_sqs_queue" "results" {
  name = local.queue_name

  # Visibility timeout >= 6× Lambda timeout (Lambda timeout = 30s)
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.results_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.module_tags, {
    Name = local.queue_name
    Role = "primary"
  })
}

data "aws_iam_policy_document" "results_queue" {
  statement {
    sid    = "AllowSNSPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.results.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.sns_topic_arn]
    }
  }

  statement {
    sid    = "AllowLabRoleConsume"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.principal_arn]
    }

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ChangeMessageVisibility",
    ]

    resources = [aws_sqs_queue.results.arn]
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.results.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "results" {
  queue_url = aws_sqs_queue.results.id
  policy    = data.aws_iam_policy_document.results_queue.json
}

resource "aws_sns_topic_subscription" "results_sqs" {
  topic_arn = var.sns_topic_arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.results.arn
}

resource "aws_cloudwatch_log_group" "writer" {
  # checkov:skip=CKV_AWS_158: AWS Academy no permite KMS CMK; cifrado con clave AWS-owned.
  # checkov:skip=CKV_AWS_338: retención corta acorde al alcance académico.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.module_tags, {
    Name = local.log_group_name
  })
}

resource "aws_security_group" "writer_lambda" {
  name        = format("%s-writer-lambda-sg", var.project)
  description = "Lambda results-writer; no ingress; egress to VPC endpoints (tcp/443) and RDS (tcp/5432). Cross-module SG rules are managed in the root composition."
  vpc_id      = var.vpc_id

  tags = merge(local.module_tags, {
    Name = format("%s-writer-lambda-sg", var.project)
  })
}

resource "aws_vpc_security_group_egress_rule" "writer_to_endpoints" {
  security_group_id            = aws_security_group.writer_lambda.id
  description                  = "HTTPS hacia los Interface VPC Endpoints (Logs, SQS, SNS)"
  referenced_security_group_id = var.endpoint_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  tags = local.module_tags
}

data "archive_file" "writer_handler" {
  type        = "zip"
  output_path = "${path.module}/handler.zip"
  source_file = "${path.module}/handler.py"
}

resource "aws_lambda_function" "writer" {
  # checkov:skip=CKV_AWS_272: Code signing no configurado en lab académico.
  # checkov:skip=CKV_AWS_50: X-Ray tracing deshabilitado en lab.
  # checkov:skip=CKV_AWS_116: DLQ a nivel Lambda no necesario; se usa el DLQ de la cola SQS.
  # checkov:skip=CKV_AWS_117: Lambda desplegada en VPC para acceder a RDS en subnets privadas.
  function_name = local.function_name
  role          = var.principal_arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 30
  memory_size   = 256
  layers        = [var.psycopg2_layer_arn]

  filename         = data.archive_file.writer_handler.output_path
  source_code_hash = data.archive_file.writer_handler.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.writer_lambda.id]
  }

  environment {
    variables = {
      DB_HOST     = var.db_host
      DB_PORT     = tostring(var.db_port)
      DB_NAME     = var.db_name
      DB_USER     = var.db_username
      DB_PASSWORD = var.db_password
    }
  }

  depends_on = [aws_cloudwatch_log_group.writer]

  tags = merge(local.module_tags, {
    Name = local.function_name
  })
}

resource "aws_lambda_event_source_mapping" "sqs_results" {
  event_source_arn                   = aws_sqs_queue.results.arn
  function_name                      = aws_lambda_function.writer.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 30
  enabled                            = true
}
