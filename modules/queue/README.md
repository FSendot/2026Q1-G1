# `modules/queue`

Provisions the SQS Standard queue that decouples the producer (transaction ingestion) from the consumer (Fargate scoring tasks), plus a Dead Letter Queue (DLQ) and a redrive policy.

## Resources

- `aws_sqs_queue.main` — primary queue `<project>-transactions`. SSE-SQS enabled, configurable visibility timeout and retention. Redrive points at the DLQ with `maxReceiveCount = 5` (configurable).
- `aws_sqs_queue.dlq` — `<project>-transactions-dlq`. SSE-SQS, 14-day retention by default.
- `aws_sqs_queue_redrive_allow_policy.dlq` — restricts which queues can use this DLQ (only the main queue, by ARN).
- `aws_sqs_queue_policy.{main,dlq}` — least-privilege policies that:
  - Allow the supplied `principal_arn` (LabRole) to publish and consume.
  - Deny any access over plain HTTP (`aws:SecureTransport = false`).

## Inputs

| Name                            | Type          | Default     | Description                                                          |
| ------------------------------- | ------------- | ----------- | -------------------------------------------------------------------- |
| `project`                       | `string`      | n/a         | Prefix for queue names.                                              |
| `tags`                          | `map(string)` | `{}`        | Common tags merged with `Component = "queue"`.                       |
| `principal_arn`                 | `string`      | n/a         | IAM role ARN allowed by the queue policy (typically the LabRole).    |
| `max_receive_count`             | `number`      | `5`         | Receives before a message is moved to the DLQ.                       |
| `visibility_timeout_seconds`    | `number`      | `60`        | Visibility timeout of the main queue.                                |
| `message_retention_seconds`     | `number`      | `345600`    | Retention of the main queue (4 days).                                |
| `dlq_message_retention_seconds` | `number`      | `1209600`   | Retention of the DLQ (14 days).                                      |

## Outputs

| Name         | Description                              |
| ------------ | ---------------------------------------- |
| `queue_url`  | URL of the main queue.                   |
| `queue_arn`  | ARN of the main queue.                   |
| `queue_name` | Name of the main queue.                  |
| `dlq_url`    | URL of the DLQ.                          |
| `dlq_arn`    | ARN of the DLQ.                          |
| `dlq_name`   | Name of the DLQ.                         |

## Notes

- Encryption is SSE-SQS (`sqs_managed_sse_enabled = true`). KMS-CMK is intentionally not used: AWS Academy restricts KMS key creation, and `aws/sqs` (managed key) is a non-option for SSE-SQS configuration. Checkov `CKV2_AWS_73` (KMS-managed SSE) is therefore expected to flag this; the SSE-SQS choice is the lab-friendly equivalent.
- The DLQ has its own queue policy and `aws_sqs_queue_redrive_allow_policy` so that only the configured source queue can target it.
