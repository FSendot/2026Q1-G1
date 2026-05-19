# `modules/notification/summary_queue`

Owns the SQS buffer for fraudulent scoring results that should be summarized for dashboard subscribers.

## Resources

- `aws_sqs_queue.main` — `<project>-fraud-alerts`, encrypted with SSE-SQS and retained for four days.
- `aws_sqs_queue.dlq` — `<project>-fraud-alerts-dlq`, retained for fourteen days.
- `aws_sqs_queue_policy.main` — allows `LabRole` to send and consume messages; denies insecure transport.

## Outputs

- `queue_url`
- `queue_arn`
- `queue_name`
- `dlq_arn`
