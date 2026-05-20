# `modules/network`

Provisions the private-only VPC that hosts the asynchronous fraud-scoring engine: three private subnet tiers across two Availability Zones, a Virtual Private Gateway (VGW), and gateway + interface VPC Endpoints.

The module is intentionally narrow: it does not create NAT gateways, IGWs, or public subnets. All egress to AWS services is meant to flow through VPC Endpoints, never the public internet.

## Three-tier subnet layout

| Tier | VPC module input | Tag `Tier` | CIDR (2 AZs, `10.0.0.0/16`) | Resources |
| ---- | ---------------- | ---------- | ----------------------------- | --------- |
| App / Compute | `private_subnets` | `app` | `10.0.0.0/20`, `10.0.16.0/20` | ECS Fargate, Lambdas (API, results-writer, summarizer) |
| Data / Isolated | `database_subnets` | `data` | `10.0.32.0/20`, `10.0.48.0/20` | RDS PostgreSQL, RDS Proxy |
| VPC Endpoints | `intra_subnets` | `endpoints` | `10.0.64.0/20`, `10.0.80.0/20` | Interface VPCE ENIs (SQS, ECR, Logs, SNS, Secrets, Cognito) |

CIDRs are computed with `cidrsubnet(var.vpc_cidr, 4, index)` where app uses indices `0..n-1`, data uses `n..2n-1`, and endpoints uses `2n..3n-1`.

### Routing

- **App route tables**: Gateway VPC Endpoints for **S3** and **DynamoDB** only. No VGW propagation.
- **Data route tables**: Isolated — no gateway endpoints, no VGW propagation.
- **Endpoint route tables**: VGW route propagation enabled so on-prem traffic can reach SQS Interface VPCE ENIs over the Site-to-Site VPN.

## Architecture summary

- Wraps `terraform-aws-modules/vpc/aws ~> 5.13` to create:
  - The VPC itself.
  - Three subnet tiers (`private_subnets`, `database_subnets`, `intra_subnets`), one subnet per AZ per tier.
  - The VGW attached to the VPC, with route propagation enabled only on endpoint (intra) route tables.
  - The default security group locked down (no ingress, no egress).
- Provisions Gateway VPC Endpoints for **S3** and **DynamoDB**, attached to **app** route tables only.
- Provisions Interface VPC Endpoints for **SQS**, **ECR API**, **ECR DKR**, **CloudWatch Logs**, **SNS**, and **Secrets Manager** in **endpoint** subnets, all sharing one security group.
- Provisions **Cognito IDP** as a separate Interface VPC Endpoint only in endpoint subnets whose AZ is supported by the service.
- Creates a dedicated SG `<project>-endpoints-sg` that accepts HTTPS from **app subnet CIDRs** and optional additional client CIDRs (e.g. the simulated on-prem VPC when it reaches SQS through the VPN).

## Inputs

| Name       | Type           | Default | Description                                                                            |
| ---------- | -------------- | ------- | -------------------------------------------------------------------------------------- |
| `project`  | `string`       | n/a     | Prefix for all resource names (`<project>-vpc`, `<project>-endpoints-sg`, ...).        |
| `vpc_cidr` | `string`       | n/a     | Primary CIDR block of the VPC. Must be a valid IPv4 CIDR.                              |
| `azs`      | `list(string)` | n/a     | Availability Zones (≥2) where all three subnet tiers are created.                      |
| `additional_endpoint_client_cidrs` | `list(string)` | `[]` | Extra CIDRs allowed to connect to Interface VPC Endpoints over HTTPS. |
| `tags`     | `map(string)`  | `{}`    | Common tags merged into every resource. The module also adds `Component = "network"`.  |

## Outputs

| Name                         | Description                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| `vpc_id`                     | ID of the VPC.                                                                             |
| `vpc_cidr`                   | CIDR block of the VPC.                                                                     |
| `app_subnet_ids`             | App-tier subnet IDs (one per AZ); passed to `modules/compute`, `modules/api`, Lambdas.     |
| `data_subnet_ids`            | Data-tier subnet IDs (one per AZ); passed to `modules/data_store`.                         |
| `endpoint_subnet_ids`        | Endpoint-tier subnet IDs (one per AZ); diagnostics.                                        |
| `private_subnet_ids`         | Alias of `app_subnet_ids` (deprecated).                                                    |
| `app_route_table_ids`        | App route table IDs (gateway VPCE routes).                                                 |
| `private_route_table_ids`    | Alias of `app_route_table_ids` (deprecated).                                               |
| `endpoint_security_group_id` | SG attached to the interface endpoints. Task SGs must allow egress to this SG on tcp/443.  |
| `vpn_gateway_id`             | VGW ID (consumed by `modules/onprem_sim` for the Site-to-Site VPN).                        |
| `interface_endpoint_ids`     | Map service → endpoint ID for `sqs`, `ecr_api`, `ecr_dkr`, `logs`, `sns`, `secretsmanager`, `cognito_idp`. |
| `cognito_idp_subnet_ids`     | Endpoint subnet IDs where the Cognito IDP endpoint was placed (AZ-filtered).               |
| `sqs_vpc_endpoint_network_interface_ids` | ENI IDs of the SQS Interface VPC Endpoint (one per endpoint subnet). Passed to `modules/onprem_sim` for the SQS private zone. |
| `gateway_endpoint_ids`       | Map service → endpoint ID for `s3`, `dynamodb`.                                            |

## Example

```hcl
module "network" {
  source = "./modules/network"

  project  = local.project
  vpc_cidr = local.vpc_cidr
  azs      = local.azs
  tags     = local.common_tags
}
```

## Terraform features used (academic checklist)

- **External module**: `terraform-aws-modules/vpc/aws ~> 5.13`.
- **Functions**: `cidrsubnet`, `format`, `merge`, `toset`, `replace`, `length`, `can`, `cidrhost`.
- **Meta-arguments**: `for_each` (gateway and interface endpoints) and `validation` blocks on every input variable. `depends_on` and `lifecycle` will be added by `modules/compute` per the project plan.

## Notes for AWS Academy

- No IAM roles or users are created.
- The default security group is locked down (`manage_default_security_group = true`, ingress/egress empty), which addresses Checkov `CKV2_AWS_12`.
- Interface endpoints accept HTTPS only from app subnet CIDRs plus explicit additional CIDRs — never `0.0.0.0/0`.
- VPC Flow Logs are intentionally not provisioned in this module (skipped to keep the lab footprint small); enabling them is a follow-up if Checkov `CKV2_AWS_11` becomes a hard requirement.

## Migration note

Moving RDS from app subnets to dedicated data subnets may force `aws_db_instance` replacement on apply. Always run `terraform plan` and snapshot RDS before applying in a non-disposable environment.
