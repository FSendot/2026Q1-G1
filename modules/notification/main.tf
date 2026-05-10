locals {
  module_tags = merge(var.tags, {
    Component = "notification"
  })

  topic_name = format("%s-results", var.project)
}

resource "aws_sns_topic" "results" {
  # checkov:skip=CKV_AWS_26: AWS Academy no permite KMS CMK; cifrado gestionado por AWS cumple el requisito at-rest.
  name = local.topic_name

  tags = merge(local.module_tags, {
    Name = local.topic_name
  })
}

data "aws_iam_policy_document" "results" {
  statement {
    sid    = "AllowLabRolePublish"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.principal_arn]
    }

    actions   = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes"]
    resources = [aws_sns_topic.results.arn]
  }

  statement {
    sid    = "AllowSNSServiceDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.results.arn]
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.results.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "results" {
  arn    = aws_sns_topic.results.arn
  policy = data.aws_iam_policy_document.results.json
}

resource "aws_sns_topic_subscription" "email_alert" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.results.arn
  protocol  = "email"
  endpoint  = var.alert_email

  filter_policy_scope = "MessageBody"
  filter_policy = jsonencode({
    is_fraud = [true]
  })
}
