# `modules/compute`

Provisions the Fargate-based scoring engine: the ECR repository, the ECS Cluster (with Container Insights), the CloudWatch log group, the task definition, the service running across two private subnets, and Application Auto Scaling tied to the SQS queue depth.

## Resources

- `aws_ecr_repository.app` — `<project>/fraud-engine`. Image tag mutability `IMMUTABLE`, scan-on-push enabled, AES256 encryption (KMS-CMK skipped — AWS Academy).
- `aws_cloudwatch_log_group.app` — `/ecs/<project>-fraud-engine`. Retention configurable via `log_retention_days`.
- `aws_ecs_cluster.main` — `<project>-cluster`, `containerInsights = enabled`.
- `aws_ecs_task_definition.app` — Fargate, awsvpc, X86_64/Linux. Both `task_role_arn` and `execution_role_arn` are passed in (LabRole in the lab). The container runs with `readonlyRootFilesystem = true`, `privileged = false`, and gets `AWS_REGION`, `QUEUE_URL`, `QUEUE_NAME`, `DYNAMODB_TABLE_NAME`, `RESULTS_QUEUE_URL`, `FRAUD_ALERT_QUEUE_URL`, `PROCESSOR_CONCURRENCY`, and `PROCESSOR_POLLERS` as env vars.
- `aws_ecs_service.app` — runs `desired_count` tasks across app-tier `private_subnet_ids`, `assign_public_ip = false`, attached to the dedicated task SG. `lifecycle { ignore_changes = [desired_count] }` so Application Auto Scaling owns the running count.
- `aws_security_group.task` — ingress empty, egress only to the endpoint SG on tcp/443.
- `aws_appautoscaling_target.ecs` — Application Auto Scaling target on `ecs:service:DesiredCount`.
- `aws_appautoscaling_policy.queue_depth_target` — `TargetTrackingScaling` with a metric math expression: `messages_per_task = ApproximateNumberOfMessagesVisible / max(RunningTaskCount, 1)`. Target value defaults to 10 messages per task.
- `aws_appautoscaling_policy.queue_depth_step` — fallback step scaling on raw `ApproximateNumberOfMessagesVisible` (1 task per +100 messages, then 2 per +100 above that). Useful while Container Insights metrics warm up.

## Inputs

| Name                              | Type           | Default | Description                                                              |
| --------------------------------- | -------------- | ------- | ------------------------------------------------------------------------ |
| `project`                         | `string`       | n/a     | Resource-name prefix.                                                    |
| `tags`                            | `map(string)`  | `{}`    | Common tags merged with `Component = "compute"`.                         |
| `vpc_id`                          | `string`       | n/a     | VPC where the service runs.                                              |
| `private_subnet_ids`              | `list(string)` | n/a     | App-tier subnets (≥2) for the service.                                    |
| `endpoint_security_group_id`      | `string`       | n/a     | Endpoint SG; the task SG only egresses here on tcp/443.                  |
| `task_role_arn`                   | `string`       | n/a     | LabRole ARN (task role).                                                 |
| `execution_role_arn`              | `string`       | n/a     | LabRole ARN (execution role).                                            |
| `image_uri`                       | `string`       | `""`    | Full image URI; CI passes `<ecr_url>:<sha>` and Terraform falls back to `<ecr_url>:placeholder` when empty. |
| `task_cpu`                        | `number`       | `512`   | Fargate CPU units.                                                       |
| `task_memory`                     | `number`       | `1024`  | Fargate memory (MiB).                                                    |
| `desired_count`                   | `number`       | `2`     | Initial task count.                                                      |
| `min_capacity`                    | `number`       | `1`     | Auto Scaling lower bound.                                                |
| `max_capacity`                    | `number`       | `10`    | Auto Scaling upper bound.                                                |
| `processor_concurrency`           | `number`       | `32`    | Concurrent message-processing workers per task.                          |
| `processor_pollers`               | `number`       | `4`     | Concurrent SQS long-pollers per task.                                    |
| `queue_arn`                       | `string`       | n/a     | SQS queue ARN.                                                           |
| `queue_url`                       | `string`       | n/a     | SQS queue URL (env var).                                                 |
| `queue_name`                      | `string`       | n/a     | SQS queue name (used in CloudWatch metric dimensions).                   |
| `table_name`                      | `string`       | n/a     | DynamoDB table name passed to the container as `DYNAMODB_TABLE_NAME`.    |
| `results_queue_url`               | `string`       | n/a     | SQS queue URL for every scoring result.                                  |
| `fraud_alert_queue_url`           | `string`       | n/a     | SQS queue URL for fraudulent results that feed summary emails.           |
| `log_retention_days`              | `number`       | `30`    | CloudWatch Logs retention.                                               |
| `scaling_target_messages_per_task`| `number`       | `10`    | Target tracking value for messages-per-task.                             |

## Outputs

| Name                              | Description                                                |
| --------------------------------- | ---------------------------------------------------------- |
| `cluster_name`                    | ECS cluster name.                                          |
| `cluster_arn`                     | ECS cluster ARN.                                           |
| `service_name`                    | ECS service name.                                          |
| `task_definition_arn`             | Active task definition ARN.                                |
| `task_security_group_id`          | SG assigned to Fargate tasks.                              |
| `ecr_repository_url`              | ECR repository URL (use to push images).                   |
| `ecr_repository_arn`              | ECR repository ARN.                                        |
| `log_group_name`                  | CloudWatch log group consumed by the awslogs driver.       |
| `autoscaling_target_resource_id`  | App Auto Scaling resource id (e.g. `service/<cl>/<svc>`).  |

## Terraform features used (academic checklist)

- **Functions**: `format`, `merge`, `jsonencode`, ternary on `image_uri`, `length` (validations), `contains` (validations).
- **Meta-arguments**:
  - `lifecycle { ignore_changes = [desired_count] }` on `aws_ecs_service.app` so Auto Scaling owns the count.
  - `depends_on` on the service waiting for the SG egress rule (and indirectly on the network module's interface endpoints, since they share the endpoint SG).
  - `validation` blocks on every variable.

## Notes for AWS Academy

- All IAM is reused from `LabRole` — the module never creates a role.
- `force_delete = true` on the ECR repo lets `terraform destroy` succeed even if images were pushed manually.
- ECR uses `image_tag_mutability = "IMMUTABLE"`; deploy pushes unique tags per commit (`processor-<sha>`).
- `image_uri = ""` produces a placeholder reference (`<ecr>:placeholder`); the first deployment will fail until you push a real image. This is intentional.
