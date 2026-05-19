# `modules/notification/summarizer`

Owns the scheduled Lambda that drains fraudulent scoring results from SQS, builds one plain-text operational summary, publishes it to SNS, and deletes processed messages only after the publish succeeds.

## Resources

- `aws_lambda_function.summarizer` — Python 3.12 Lambda in private subnets.
- `aws_cloudwatch_event_rule.schedule` and `aws_cloudwatch_event_target.summarizer` — interval trigger.
- `aws_lambda_permission.allow_eventbridge` — allows EventBridge to invoke the Lambda.
- `aws_security_group.summarizer` — no ingress, egress to the shared interface endpoint SG over TCP/443.

## Runtime

The Lambda uses only the Python standard library plus `boto3` from the AWS Lambda runtime. It receives `FRAUD_ALERT_QUEUE_URL`, `SUMMARY_TOPIC_ARN`, `MAX_MESSAGES_PER_RUN`, and `SUMMARY_INTERVAL_MINUTES` as environment variables.
