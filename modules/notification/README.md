# `modules/notification`

Provisions the SNS topic that acts as the fan-out hub for fraud-scoring results. After the Fargate engine scores a transaction and publishes the result, SNS delivers the message to every subscriber independently: the results queue (for persistence in RDS), and optionally a direct email address for fraud alerts.

## Resources

- `aws_sns_topic.results` — `<project>-results`. The central fan-out topic.
- `aws_sns_topic_policy.results` — least-privilege policy:
  - Allows the supplied `principal_arn` (LabRole) to publish and manage subscriptions.
  - Allows the SNS service itself to publish (needed for internal delivery).
  - Denies any publish over plain HTTP (`aws:SecureTransport = false`).
- `aws_sns_topic_subscription.email_alert` _(conditional)_ — native SNS email subscription created only when `var.alert_email` is non-empty. Filters on `is_fraud = true` in the message body (`filter_policy_scope = "MessageBody"`), so only confirmed fraud events trigger an email. SNS sends a confirmation email to the address; the recipient must click the link before receiving alerts.

## Inputs

| Name           | Type          | Default | Description                                                                                                                                   |
| -------------- | ------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `project`      | `string`      | n/a     | Prefix for resource names.                                                                                                                    |
| `tags`         | `map(string)` | `{}`    | Common tags merged with `Component = "notification"`.                                                                                         |
| `principal_arn`| `string`      | n/a     | IAM role ARN allowed to publish to the topic (LabRole in AWS Academy).                                                                        |
| `alert_email`  | `string`      | `""`    | Email address for fraud alert notifications (SNS native email, no SES required). Leave empty to skip. Accepts a confirmation email on first use. |

## Outputs

| Name         | Description                              |
| ------------ | ---------------------------------------- |
| `topic_arn`  | ARN of the SNS results topic.            |
| `topic_name` | Name of the SNS results topic.           |

## Example

```hcl
module "notification" {
  source = "./modules/notification"

  project       = local.project
  principal_arn = data.aws_iam_role.lab.arn
  alert_email   = var.alert_email
  tags          = local.common_tags
}
```

Downstream modules subscribe to the topic by passing `module.notification.topic_arn`:

```hcl
module "results_writer" {
  ...
  sns_topic_arn = module.notification.topic_arn
}
```

## Notes for AWS Academy

- KMS-CMK for SNS is not available in Academy (Checkov `CKV_AWS_26` skipped). The topic is unencrypted at rest; messages are encrypted in transit (HTTPS enforced by the topic policy).
- The email subscription uses SNS's native email protocol.
- The filter policy uses `filter_policy_scope = "MessageBody"` to match on the JSON payload field `is_fraud`. This requires the publishing Fargate task to include `"is_fraud": true` in the message body.
