# `modules/results_writer`

Provisions the buffered pipeline between the SNS results topic and the RDS database: an SQS queue (with DLQ) subscribed to SNS, and a Lambda function triggered by that queue that persists fraud-scoring results.

The SNS → SQS → Lambda pattern adds a buffer and automatic retries. If the Lambda fails (e.g. a transient DB timeout), the message becomes visible again after the visibility timeout and is retried up to `maxReceiveCount = 3` times before landing in the DLQ — no results are lost.

## Resources

- `aws_sqs_queue.results_dlq` — `<project>-results-events-dlq`. 14-day retention, SSE-SQS.
- `aws_sqs_queue_redrive_allow_policy.results_dlq` — restricts DLQ access to the main results queue only.
- `aws_sqs_queue.results` — `<project>-results-events`. Visibility timeout 180 s (≥6× Lambda timeout per AWS best practice). SSE-SQS. Redrive to DLQ after 3 receives.
- `aws_sqs_queue_policy.results` — allows SNS to `SendMessage` (conditioned on `aws:SourceArn = <topic-arn>`), allows LabRole to consume, denies plain HTTP.
- `aws_sns_topic_subscription.results_sqs` — subscribes the SQS queue to the SNS topic.
- `aws_cloudwatch_log_group.writer` — `/aws/lambda/<project>-results-writer`. 30-day retention by default.
- `aws_security_group.writer_lambda` — `<project>-writer-lambda-sg`. No ingress; egress to the VPC endpoint SG on tcp/443. The egress rule to RDS Proxy (tcp/5432) is created in the root composition to avoid circular module dependencies.
- `aws_lambda_function.writer` — `<project>-results-writer`. Python 3.12, 128 MiB, 30 s timeout, deployed in VPC private subnets. Receives `DB_*` env vars and connects to RDS via RDS Proxy using a psycopg2 Lambda layer.
- `aws_lambda_event_source_mapping.sqs_results` — triggers the Lambda from the results SQS queue. Batch size 10, batching window 30 s.

## Inputs

| Name                        | Type           | Default | Description                                                                      |
| --------------------------- | -------------- | ------- | -------------------------------------------------------------------------------- |
| `project`                   | `string`       | n/a     | Prefix for resource names.                                                       |
| `tags`                      | `map(string)`  | `{}`    | Common tags merged with `Component = "results-writer"`.                          |
| `principal_arn`             | `string`       | n/a     | LabRole ARN used as Lambda execution role and for SQS consume permissions.       |
| `vpc_id`                    | `string`       | n/a     | VPC where the Lambda is deployed.                                                |
| `private_subnet_ids`        | `list(string)` | n/a     | Private subnets for the Lambda VPC config.                                       |
| `endpoint_security_group_id`| `string`       | n/a     | VPC endpoint SG; the Lambda opens egress tcp/443 here (Logs, SQS endpoints).    |
| `sns_topic_arn`             | `string`       | n/a     | ARN of the SNS results topic to subscribe the SQS queue to.                     |
| `db_host`                   | `string`       | n/a     | RDS hostname (`DB_HOST` env var).                                                |
| `db_port`                   | `number`       | `5432`  | RDS port (`DB_PORT` env var).                                                    |
| `db_name`                   | `string`       | `"fraud_results"` | Database name (`DB_NAME` env var).                                     |
| `db_username`               | `string`       | `"fraud_admin"` | Master username (`DB_USER` env var).                                       |
| `db_password`               | `string`       | n/a     | Master password. `sensitive = true`. Passed as `DB_PASSWORD` env var.            |
| `log_retention_days`        | `number`       | `30`    | CloudWatch Logs retention days.                                                  |

## Outputs

| Name                      | Description                                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `queue_arn`               | ARN of the results SQS queue.                                                                                      |
| `queue_url`               | URL of the results SQS queue.                                                                                      |
| `queue_name`              | Name of the results SQS queue.                                                                                     |
| `dlq_arn`                 | ARN of the DLQ.                                                                                                    |
| `lambda_function_name`    | Name of the results-writer Lambda.                                                                                 |
| `lambda_function_arn`     | ARN of the results-writer Lambda.                                                                                  |
| `lambda_security_group_id`| Lambda SG ID. Exposed so the root composition can add the egress rule to RDS Proxy without circular module dependencies. |
| `log_group_name`          | CloudWatch log group name.                                                                                         |

## Example

```hcl
module "results_writer" {
  source = "./modules/results_writer"

  project                    = local.project
  principal_arn              = data.aws_iam_role.lab.arn
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  endpoint_security_group_id = module.network.endpoint_security_group_id
  sns_topic_arn              = module.notification.topic_arn
  db_host                    = module.data_store.proxy_endpoint
  db_port                    = module.data_store.db_port
  db_name                    = module.data_store.db_name
  db_username                = module.data_store.db_username
  db_password                = random_password.db.result
  tags                       = local.common_tags
}
```

## Notes for AWS Academy

- Checkov `CKV_AWS_272` (code signing), `CKV_AWS_50` (X-Ray), and `CKV_AWS_116` (Lambda DLQ) are skipped. The SQS queue's DLQ provides the equivalent retry/dead-letter guarantee for the Lambda.
- `LabRole` is used as the Lambda execution role (Academy restriction). It already has the required `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `ec2:CreateNetworkInterface`, and `logs:CreateLogGroup` permissions.
