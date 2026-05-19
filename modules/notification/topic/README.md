# `modules/notification/topic`

Owns the SNS topic used only for fraud-summary emails. The processor never publishes raw transaction results here; the scheduled summarizer publishes one compact message per non-empty interval.

## Resources

- `aws_sns_topic.summary` — `<project>-fraud-summaries`.
- `aws_sns_topic_policy.summary` — allows `LabRole` to publish, subscribe, unsubscribe, and inspect topic subscriptions; denies insecure transport.

## Outputs

- `topic_arn`
- `topic_name`
