# `modules/notification/summarizer`

Owns the scheduled Lambda infrastructure that runs the fraud-summary code from `app/notification/summarizer/handler.py`.

## Resources

- `aws_lambda_function.summarizer` — Python 3.12 Lambda in private subnets.
- `aws_cloudwatch_event_rule.schedule` and `aws_cloudwatch_event_target.summarizer` — interval trigger.
- `aws_lambda_permission.allow_eventbridge` — allows EventBridge to invoke the Lambda.
- `aws_security_group.summarizer` — no ingress, egress to the shared interface endpoint SG over TCP/443.

## Runtime

The deployment zip is passed through `var.package_file` (built in the root composition from `app/notification/summarizer/handler.py`). This submodule should stay infrastructure-only. The Lambda receives `FRAUD_ALERT_QUEUE_URL`, `SUMMARY_TOPIC_ARN`, `MAX_MESSAGES_PER_RUN`, and `SUMMARY_INTERVAL_MINUTES` as environment variables.
