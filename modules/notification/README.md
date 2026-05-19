# `modules/notification`

Composition module for fraud-alert summaries. It owns three isolated submodules:

- `topic` — SNS topic `<project>-fraud-summaries` where summary notifications are published.
- `summary_queue` — SQS queue `<project>-fraud-alerts` and DLQ where fraudulent transaction results accumulate.
- `summarizer` — EventBridge scheduled Lambda that drains the alert queue and publishes a compact summary to the SNS topic.

The processor publishes all scoring results directly to `modules/results_writer` and sends only fraudulent results directly to `module.notification.fraud_alert_queue_url`. The summarizer runs on a fixed EventBridge interval, reads pending fraud alerts from SQS, publishes one summary message, and deletes the processed messages after a successful publish.

## Resources

- `module.topic.aws_sns_topic.summary` — `<project>-fraud-summaries`.
- `module.topic.aws_sns_topic_policy.summary` — allows LabRole topic operations and denies insecure transport.
- `module.summary_queue.aws_sqs_queue.main` — `<project>-fraud-alerts`, 4-day retention, 180 s visibility timeout, SSE-SQS.
- `module.summary_queue.aws_sqs_queue.dlq` — `<project>-fraud-alerts-dlq`, 14-day retention.
- `module.summary_queue.aws_sqs_queue_policy.main` — allows LabRole direct `sqs:SendMessage` plus consume, denies insecure transport.
- `module.summarizer.aws_lambda_function.summarizer` — Python 3.12 scheduled summarizer in private subnets.
- `module.summarizer.aws_cloudwatch_event_rule.schedule` — `rate(<summary_interval_minutes> minutes)`.

## Inputs

| Name                               | Type           | Default | Description |
| ---------------------------------- | -------------- | ------- | ----------- |
| `project`                          | `string`       | n/a     | Prefix for resource names. |
| `tags`                             | `map(string)`  | `{}`    | Common tags merged with notification component tags. |
| `principal_arn`                    | `string`       | n/a     | LabRole ARN used to operate SNS/SQS and execute the Lambda. |
| `vpc_id`                           | `string`       | n/a     | VPC where the summarizer Lambda runs. |
| `private_subnet_ids`               | `list(string)` | n/a     | Private subnets for the summarizer Lambda. |
| `endpoint_security_group_id`       | `string`       | n/a     | Interface endpoint SG for Lambda egress to Logs, SQS, and SNS. |
| `summarizer_package_file`          | `string`       | n/a     | Path to the pre-built summarizer Lambda zip (from `app/notification/summarizer/handler.py` at root). |
| `summary_interval_minutes`         | `number`       | `7`     | EventBridge schedule interval for summary publication. Root passes `var.fraud_alert_summary_interval_minutes`. |
| `summarizer_max_messages_per_run`  | `number`       | `500`   | Maximum SQS messages drained by each scheduled run. |
| `log_retention_days`               | `number`       | `30`    | CloudWatch log retention for the summarizer Lambda. |

## Outputs

| Name                              | Description |
| --------------------------------- | ----------- |
| `topic_arn`                       | ARN of the summary SNS topic. |
| `topic_name`                      | Name of the summary SNS topic. |
| `fraud_alert_queue_url`           | URL of the fraud-alert queue. |
| `fraud_alert_queue_arn`           | ARN of the fraud-alert queue. |
| `fraud_alert_queue_name`          | Name of the fraud-alert queue. |
| `fraud_alert_dlq_arn`             | ARN of the fraud-alert DLQ. |
| `summarizer_lambda_function_name` | Name of the scheduled summarizer Lambda. |
| `summarizer_security_group_id`    | Security group ID of the summarizer Lambda. |
| `summarizer_schedule_name`        | Name of the EventBridge schedule rule. |

## Example

```hcl
module "notification" {
  source = "./modules/notification"

  project                    = local.project
  principal_arn              = data.aws_iam_role.lab.arn
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  endpoint_security_group_id = module.network.endpoint_security_group_id
  summarizer_package_file    = data.archive_file.notification_summarizer.output_path
  summary_interval_minutes   = var.fraud_alert_summary_interval_minutes
  tags                       = local.common_tags
}
```

## Notes for AWS Academy

- KMS-CMK for SNS, SQS, and CloudWatch Logs is not available in Academy; resources use AWS-owned or SQS-managed encryption where supported.
- `LabRole` is reused for Lambda execution and queue access because the lab restricts IAM role creation.
- The summarizer business logic lives in `app/notification/summarizer/handler.py`; the root composition builds the zip in `lambdas.tf` and passes `summarizer_package_file`.
- The Lambda is dependency-free and keeps failed publishes retryable by deleting SQS messages only after `sns:Publish` succeeds.
