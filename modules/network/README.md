# `modules/network`

Provisions the private-only VPC that hosts the asynchronous fraud-scoring engine: two private subnets across two Availability Zones, a Virtual Private Gateway (VGW), and gateway + interface VPC Endpoints.

The module is intentionally narrow: it does not create NAT gateways, IGWs, or public subnets. All egress to AWS services is meant to flow through VPC Endpoints, never the public internet.

## Architecture summary

- Wraps `terraform-aws-modules/vpc/aws ~> 5.13` to create:
  - The VPC itself.
  - `length(var.azs)` private subnets, sized with `cidrsubnet(var.vpc_cidr, 4, i)`.
  - The VGW attached to the VPC, with route propagation enabled on private route tables (ready for a future Customer Gateway / `aws_vpn_connection`).
  - The default security group locked down (no ingress, no egress).
- Provisions Gateway VPC Endpoints for **S3** and **DynamoDB**, attached to all private route tables.
- Provisions Interface VPC Endpoints for **SQS**, **ECR API**, **ECR DKR**, **CloudWatch Logs**, and **SNS** in each private subnet, all sharing one security group. The SNS endpoint allows Fargate tasks and Lambda functions to publish to SNS topics without a NAT gateway.
- Creates a dedicated SG `<project>-endpoints-sg` that accepts HTTPS only from the VPC CIDR.

## Inputs

| Name       | Type           | Default | Description                                                                            |
| ---------- | -------------- | ------- | -------------------------------------------------------------------------------------- |
| `project`  | `string`       | n/a     | Prefix for all resource names (`<project>-vpc`, `<project>-endpoints-sg`, ...).        |
| `vpc_cidr` | `string`       | n/a     | Primary CIDR block of the VPC. Must be a valid IPv4 CIDR.                              |
| `azs`      | `list(string)` | n/a     | Availability Zones (≥2) where private subnets are created.                             |
| `tags`     | `map(string)`  | `{}`    | Common tags merged into every resource. The module also adds `Component = "network"`.  |

## Outputs

| Name                         | Description                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------ |
| `vpc_id`                     | ID of the VPC.                                                                             |
| `vpc_cidr`                   | CIDR block of the VPC.                                                                     |
| `private_subnet_ids`         | List of private subnet IDs (one per AZ), passed to the ECS service in `modules/compute`.   |
| `private_route_table_ids`    | Private route table IDs.                                                                   |
| `endpoint_security_group_id` | SG attached to the interface endpoints. Task SGs must allow egress to this SG on tcp/443.  |
| `vpn_gateway_id`             | VGW ID (consumed by `modules/onprem_sim` for the Site-to-Site VPN).                        |
| `interface_endpoint_ids`     | Map service → endpoint ID for `sqs`, `ecr_api`, `ecr_dkr`, `logs`, `sns`.                  |
| `sqs_vpc_endpoint_network_interface_ids` | ENI IDs of the SQS Interface VPC Endpoint (one per private subnet). Passed to `modules/onprem_sim` for the SQS private zone. |
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
- Interface endpoints accept HTTPS only from the VPC CIDR — never `0.0.0.0/0`.
- VPC Flow Logs are intentionally not provisioned in this module (skipped to keep the lab footprint small); enabling them is a follow-up if Checkov `CKV2_AWS_11` becomes a hard requirement.
