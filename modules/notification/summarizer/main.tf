data "aws_region" "current" {}

locals {
  module_tags = merge(var.tags, {
    Component = "notification-summarizer"
  })

  function_name  = format("%s-fraud-summary", var.project)
  log_group_name = format("/aws/lambda/%s-fraud-summary", var.project)
  schedule_name  = format("%s-fraud-summary-schedule", var.project)
  schedule_expression = var.summary_interval_minutes == 1 ? "rate(1 minute)" : format(
    "rate(%d minutes)",
    var.summary_interval_minutes,
  )
}

resource "aws_cloudwatch_log_group" "summarizer" {
  # checkov:skip=CKV_AWS_158: AWS Academy no permite KMS CMK; cifrado con clave AWS-owned.
  # checkov:skip=CKV_AWS_338: retención corta acorde al alcance académico.
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.module_tags, {
    Name = local.log_group_name
  })
}

resource "aws_security_group" "summarizer" {
  name        = format("%s-fraud-summary-sg", var.project)
  description = "Lambda summarizer; no ingress; egress to Interface VPC Endpoints over tcp/443."
  vpc_id      = var.vpc_id

  tags = merge(local.module_tags, {
    Name = format("%s-fraud-summary-sg", var.project)
  })
}

resource "aws_vpc_security_group_egress_rule" "summarizer_to_endpoints" {
  security_group_id            = aws_security_group.summarizer.id
  description                  = "HTTPS hacia los Interface VPC Endpoints (Logs, SQS, SNS)"
  referenced_security_group_id = var.endpoint_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  tags = local.module_tags
}

data "archive_file" "summarizer" {
  type        = "zip"
  output_path = "${path.module}/handler.zip"
  source_file = "${path.module}/handler.py"
}

resource "aws_lambda_function" "summarizer" {
  # checkov:skip=CKV_AWS_272: Code signing no configurado en lab académico.
  # checkov:skip=CKV_AWS_50: X-Ray tracing deshabilitado en lab.
  # checkov:skip=CKV_AWS_116: Los mensajes quedan en SQS si falla la publicación; la cola tiene DLQ.
  function_name = local.function_name
  role          = var.principal_arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.summarizer.output_path
  source_code_hash = data.archive_file.summarizer.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.summarizer.id]
  }

  environment {
    variables = {
      FRAUD_ALERT_QUEUE_URL    = var.fraud_alert_queue_url
      SUMMARY_TOPIC_ARN        = var.summary_topic_arn
      MAX_MESSAGES_PER_RUN     = tostring(var.summarizer_max_messages_per_run)
      SUMMARY_INTERVAL_MINUTES = tostring(var.summary_interval_minutes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.summarizer]

  tags = merge(local.module_tags, {
    Name = local.function_name
  })
}

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = local.schedule_name
  description         = "Publica un resumen de transacciones fraudulentas pendientes."
  schedule_expression = local.schedule_expression

  tags = merge(local.module_tags, {
    Name = local.schedule_name
  })
}

resource "aws_cloudwatch_event_target" "summarizer" {
  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "fraud-summary"
  arn       = aws_lambda_function.summarizer.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.summarizer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
