# `modules/data_store`

Provisions the single DynamoDB table that the fraud-scoring service uses to read user-level behavioural features.

## Resource

- `aws_dynamodb_table.user_behavior` — `<project>-user-behavior`.
  - `billing_mode = PAY_PER_REQUEST` (no capacity planning needed for the lab).
  - `hash_key = user_id` (string), no sort key.
  - Server-side encryption enabled (AWS-owned key, AES256).
  - Point-In-Time Recovery enabled by default.
  - Deletion protection toggleable (off by default for lab cleanup).

## Inputs

| Name                            | Type          | Default       | Description                                                          |
| ------------------------------- | ------------- | ------------- | -------------------------------------------------------------------- |
| `project`                       | `string`      | n/a           | Prefix for the table name.                                           |
| `tags`                          | `map(string)` | `{}`          | Common tags merged with `Component = "data-store"`.                  |
| `hash_key_name`                 | `string`      | `"user_id"`   | Name of the partition key attribute.                                 |
| `enable_point_in_time_recovery` | `bool`        | `true`        | Toggle PITR for the table.                                           |
| `enable_deletion_protection`    | `bool`        | `false`       | Toggle DynamoDB deletion protection.                                 |

## Outputs

| Name             | Description                                       |
| ---------------- | ------------------------------------------------- |
| `table_name`     | Name of the DynamoDB table.                       |
| `table_arn`      | ARN of the table.                                 |
| `table_id`       | Internal table id (same as name).                 |
| `hash_key_name`  | Partition key attribute name (echoed back).       |

## Notes

- AWS Academy does not allow customer-managed KMS keys. The table uses the AWS-owned default key, which still satisfies the basic SSE requirement (Checkov `CKV_AWS_28`). KMS-CMK (`CKV_AWS_119`) is intentionally not used.
- The TP requires only one table — there are no GSIs or LSIs by design.
