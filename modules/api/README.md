# `modules/api`

Provisions the dashboard API: a Lambda function running inside the VPC (to reach the private RDS instance) exposed via an HTTP API Gateway. The routes are protected with a JWT authorizer backed by Cognito, and return fraud-scoring results stored in PostgreSQL.

## Resources

- `aws_cloudwatch_log_group.api_lambda` — `/aws/lambda/<project>-api`. 30-day retention by default.
- `aws_cloudwatch_log_group.api_gw` — `/aws/apigateway/<project>-api`. 30-day retention by default.
- `aws_security_group.api_lambda` — `<project>-api-lambda-sg`. No ingress; egress to the VPC endpoint SG on tcp/443 (Logs). The egress rule to RDS Proxy (tcp/5432) is created in the root composition to avoid circular module dependencies.
- `aws_lambda_function.api` — `<project>-api`. Python 3.12, 256 MiB, 15 s timeout, deployed in VPC private subnets. Receives `DB_*` env vars and uses the psycopg2 Lambda layer to query RDS.
- `aws_apigatewayv2_api.main` — `<project>-api`. HTTP API (not REST API — simpler, cheaper). CORS configured for dashboard read/admin methods from any origin.
- `aws_apigatewayv2_stage.default` — `$default` stage with `auto_deploy = true`.
- `aws_apigatewayv2_integration.lambda` — `AWS_PROXY` integration, payload format version `2.0`.
- `aws_apigatewayv2_authorizer.jwt` — JWT authorizer using the Cognito issuer and audience passed from the root composition.
- `aws_apigatewayv2_route.get_transactions` — `GET /transactions`.
- `aws_apigatewayv2_route.get_health` — `GET /health`.
- Dashboard auth routes — `GET /dashboard/me`, `PUT /dashboard/me/password`, `GET|POST /dashboard/invites`, `DELETE /dashboard/invites/{id}`.
- `aws_apigatewayv2_route.cors_preflight` — unauthenticated `OPTIONS /{proxy+}` so browser CORS preflight is handled by API Gateway before the JWT-protected `$default` route.
- `aws_lambda_permission.api_gw` — allows API Gateway (`apigateway.amazonaws.com`) to invoke the Lambda, scoped to this API's execution ARN.

## Inputs

| Name                        | Type           | Default | Description                                                                   |
| --------------------------- | -------------- | ------- | ----------------------------------------------------------------------------- |
| `project`                   | `string`       | n/a     | Prefix for resource names.                                                    |
| `tags`                      | `map(string)`  | `{}`    | Common tags merged with `Component = "api"`.                                  |
| `principal_arn`             | `string`       | n/a     | LabRole ARN used as Lambda execution role.                                    |
| `vpc_id`                    | `string`       | n/a     | VPC where the Lambda is deployed.                                             |
| `private_subnet_ids`        | `list(string)` | n/a     | Private subnets for the Lambda VPC config.                                    |
| `endpoint_security_group_id`| `string`       | n/a     | VPC endpoint SG; the Lambda opens egress tcp/443 here (Logs endpoint).        |
| `db_host`                   | `string`       | n/a     | RDS hostname (`DB_HOST` env var).                                             |
| `db_port`                   | `number`       | `5432`  | RDS port (`DB_PORT` env var).                                                 |
| `db_name`                   | `string`       | `"fraud_results"` | Database name (`DB_NAME` env var).                                  |
| `db_username`               | `string`       | `"fraud_admin"` | Master username (`DB_USER` env var).                                    |
| `db_password`               | `string`       | n/a     | Master password. `sensitive = true`. Passed as `DB_PASSWORD` env var.         |
| `jwt_issuer`                | `string`       | n/a     | Cognito issuer URL used by the JWT authorizer.                                 |
| `jwt_audience`              | `string`       | n/a     | Cognito app client ID used as JWT audience.                                    |
| `log_retention_days`        | `number`       | `30`    | CloudWatch Logs retention days (Lambda and API Gateway log groups).           |

## Outputs

| Name                      | Description                                                                                                     |
| ------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `api_endpoint`            | Base URL of the HTTP API Gateway (e.g. `https://<id>.execute-api.<region>.amazonaws.com`).                      |
| `api_id`                  | HTTP API Gateway ID.                                                                                            |
| `lambda_function_name`    | Name of the API Lambda.                                                                                         |
| `lambda_function_arn`     | ARN of the API Lambda.                                                                                          |
| `lambda_security_group_id`| Lambda SG ID. Exposed so the root composition can add the egress rule to RDS Proxy without circular module dependencies. |
| `log_group_name`          | CloudWatch log group name for the Lambda.                                                                       |

## Example

```hcl
module "api" {
  source = "./modules/api"

  project                    = local.project
  principal_arn              = data.aws_iam_role.lab.arn
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  endpoint_security_group_id = module.network.endpoint_security_group_id
  db_host                    = module.data_store.proxy_endpoint
  db_port                    = module.data_store.db_port
  db_name                    = module.data_store.db_name
  db_username                = module.data_store.db_username
  db_password                = random_password.db.result
  jwt_issuer                 = module.auth.issuer
  jwt_audience               = module.auth.client_id
  tags                       = local.common_tags
}
```

The dashboard endpoint after apply:

```
GET <api_endpoint>/transactions
Authorization: Bearer <cognito-id-token>
```

## Lambda instead of Fargate

The dashboard API is intentionally Lambda-based. It serves low-volume, request-driven dashboard reads from RDS and does not consume queues or maintain background workers. Keeping it as Lambda avoids an always-running Fargate service and a load balancer, which fits the AWS Academy cost and simplicity constraints. `app/api/Dockerfile` is still built in CI as a packaging/runtime check, but the image is not pushed to ECR because every ECR image in this repo should have a Fargate owner.

## Notes for AWS Academy

- Checkov `CKV_AWS_272` (code signing), `CKV_AWS_50` (X-Ray), `CKV_AWS_116` (Lambda DLQ), `CKV2_AWS_29` (WAF), and `CKV_AWS_76` (API Gateway access logging) are skipped — all are lab cost or Academy restriction trade-offs.
- `LabRole` is used as the Lambda execution role (Academy restriction).
- API Gateway is public at the network edge. Real data routes use the Cognito JWT authorizer; only `OPTIONS /{proxy+}` is unauthenticated so browser CORS preflight can complete. In production, also consider a resource policy or WAF.
