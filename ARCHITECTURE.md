# Architecture — Asynchronous Fraud-Scoring Engine

This document describes the **target architecture** provisioned by this repository, the **trade-offs**, and the **explicit non-goals** of the current iteration. The Terraform composition is the single source of truth; this document only summarizes intent.



## 1. Context

The system scores incoming financial transactions for fraud asynchronously. Producers (out of scope of this repo) drop transactions on a queue; a horizontally-scaled pool of containers reads them, enriches each one with the user's recent behaviour from a key-value store, runs a scoring model, and writes the outcome.

Hard constraints driving the design:

- **AWS Academy** lab: short-lived account, no permission to create new IAM users/roles. Workloads must reuse `LabRole`.
- Reproducibility: every cloud change must live in code; no console clicks.
- Cost: the lab account is small. We avoid NAT gateways, customer-managed KMS keys, and multi-region setups.



## 3. Components

| Component                              | Module             | Type      | Notes                                                                                                          |
| -------------------------------------- | ------------------ | --------- | -------------------------------------------------------------------------------------------------------------- |
| VPC, private subnets, VGW, default SG  | `modules/network`  | external + custom | Wraps `terraform-aws-modules/vpc/aws ~> 5.13`. No NAT, no IGW.                                          |
| Gateway VPC Endpoints (S3, DynamoDB)   | `modules/network`  | custom    | Attached to all private route tables.                                                                          |
| Interface VPC Endpoints (SQS, ECR-API, ECR-DKR, Logs) | `modules/network` | custom | One shared SG (`<project>-endpoints-sg`) accepts HTTPS only from the VPC CIDR.                       |
| SQS main queue + DLQ + redrive         | `modules/queue`    | custom    | `maxReceiveCount = 5`. SSE-SQS. Queue policy restricted to LabRole.                                            |
| DynamoDB `user_behavior` table         | `modules/data_store` | custom  | PK `user_id` (string), `PAY_PER_REQUEST`, SSE on, PITR on.                                                      |
| ECR repo                               | `modules/compute`  | custom    | `IMMUTABLE` tags, scan-on-push.                                                                                 |
| ECS Cluster (Container Insights on)    | `modules/compute`  | custom    | Single cluster.                                                                                                 |
| Fargate task definition                | `modules/compute`  | custom    | LabRole as both task and execution role (lab constraint).                                                       |
| ECS service (2 tasks, private subnets) | `modules/compute`  | custom    | `assign_public_ip = false`, `lifecycle { ignore_changes = [desired_count] }` so autoscaling owns capacity.       |
| Application Auto Scaling on queue depth | `modules/compute` | custom    | Target tracking with metric math (`messages / max(running, 1)`), step scaling fallback on raw `Visible` metric. |
| On-prem simulated VPC + CGW + Site-to-Site VPN | `modules/onprem_sim` | custom + embedded CFN | Public-only `192.168.0.0/16` VPC with one EC2 strongSwan router (deployed via `aws_cloudformation_stack` consuming `templates/vpn-gateway-strongswan.yml`). BGP-based `aws_vpn_connection` against the VGW. Gated by `var.enable_onprem_sim` (default `true`). |

## 4. Data and control flow

1. A producer (out of scope) calls `SendMessage` on the SQS main queue using the SQS Interface VPC Endpoint.
2. Fargate tasks consume from the queue, look up the user's behaviour features in DynamoDB via the DynamoDB Gateway Endpoint, run scoring, and write the outcome (also via Gateway Endpoint, in a future iteration).
3. Failures are retried via SQS visibility timeout. After `maxReceiveCount = 5` deliveries, the message moves to the DLQ.
4. CloudWatch Logs receives container logs through the Logs Interface Endpoint.
5. ECR holds the container image, pulled through ECR API + DKR Endpoints.
6. Application Auto Scaling reads the queue depth and the running task count and adjusts `desired_count` so the queue stays close to the target backlog per task.

There is **no public ingress** to the AWS VPC. The VGW is attached and route propagation is enabled. When `var.enable_onprem_sim = true` (default), `modules/onprem_sim` provisions a separate `192.168.0.0/16` VPC with one EC2 instance running strongSwan + Quagga BGP, plus the `aws_customer_gateway` and `aws_vpn_connection` that bring up two BGP-based IPsec tunnels against the VGW. The strongSwan EC2 itself is deployed by embedding `templates/vpn-gateway-strongswan.yml` inside an `aws_cloudformation_stack`, with PSKs delivered through AWS Secrets Manager.

## 5. Trade-offs and explicit non-goals

- **No NAT Gateway** — saves cost and forces all egress through VPC endpoints.
- **No customer-managed KMS keys** — AWS Academy disallows KMS CMK creation. AWS-owned/managed keys are used everywhere (S3 SSE-S3, DynamoDB SSE-AWS, SQS SSE-SQS, ECR AES256). Checkov findings for this are documented and skipped on the affected resources.
- **`LabRole` as both task and execution role** — AWS Academy disallows creating new roles. Documented `CKV_AWS_249` skip on `aws_ecs_task_definition`.
- **On-prem simulation is BGP-only and single-AZ.** `modules/onprem_sim` is intentionally minimal (one public subnet, permissive SG, one EC2 router). It can be disabled with `var.enable_onprem_sim = false` to skip both the VPN connection costs and the strongSwan stack rollout.
- **No VPC Flow Logs** — intentionally skipped for the lab footprint. Re-enable later when the Checkov `CKV2_AWS_11` finding becomes a hard requirement.
- **Application image** is built and pushed outside Terraform. The ECR repo is provisioned empty; the first deployment fails until a real image is pushed.
- **Local Terraform backend.** Remote S3+DynamoDB backend is documented as a stub in `backend.tf`.

## 6. How the academic minima are met

| Requirement (from `docs/CONSIGNA.md`) | Where in this repo                                                                                              |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| ≥1 external module                    | `terraform-aws-modules/vpc/aws ~> 5.13` in `modules/network`.                                                    |
| ≥1 custom module                      | `modules/network`, `modules/queue`, `modules/data_store`, `modules/compute`, `modules/onprem_sim` (5).          |
| ≥4 Terraform functions                | `merge`, `format`, `cidrsubnet`, `toset`, `replace`, `length`, `can`, `cidrhost`, `jsonencode`, `contains`, `slice`. |
| ≥3 meta-arguments                     | `for_each` (gateway and interface endpoints), `lifecycle { ignore_changes }` (ECS service `desired_count`, CFN stack `pAmiId`), `depends_on` (service → SG egress rule, CFN stack → secret versions + VPN), `count` (`module.onprem_sim`), plus `validation` blocks on every variable. |
