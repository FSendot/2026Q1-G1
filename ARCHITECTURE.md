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
| Interface VPC Endpoints (SQS, ECR-API, ECR-DKR, Logs, SNS) | `modules/network` | custom | One shared SG (`<project>-endpoints-sg`) accepts HTTPS only from the VPC CIDR. SNS endpoint added to allow Fargate and Lambda to publish without a NAT gateway. |
| SQS main queue + DLQ + redrive         | `modules/queue`      | custom    | `maxReceiveCount = 5`. SSE-SQS. Queue policy restricted to LabRole.                                            |
| DynamoDB `user_behavior` table         | `modules/data_store` | custom    | PK `user_id` (string), `PAY_PER_REQUEST`, SSE on, PITR on. Input to scoring.                                   |
| RDS PostgreSQL `fraud_results` DB      | `modules/data_store` | custom    | PostgreSQL 17.4, `db.t3.micro`, private subnets, encrypted. Output of scoring. Single-AZ lab configuration.    |
| RDS Proxy                              | `modules/data_store` | custom    | Connection pool between Lambdas and RDS. `require_tls = true`, `iam_auth = DISABLED`, credentials via Secrets Manager. Prevents connection exhaustion on `db.t3.micro`.  |
| SNS results topic                      | `modules/notification` | custom  | Fan-out hub: `<project>-results`. Delivers to SQS (buffered) and optionally to email (direct, `is_fraud=true` filter). |
| SQS results queue + DLQ                | `modules/results_writer` | custom | Buffer between SNS and the writer Lambda. `maxReceiveCount = 3`, visibility timeout 180 s.                   |
| Lambda results-writer                  | `modules/results_writer` | custom | Python 3.12, in VPC, triggered by SQS. Connects to RDS via RDS Proxy with a psycopg2 layer.     |
| HTTP API Gateway + Lambda              | `modules/api`        | custom    | `GET /transactions`, `GET /stats`, `GET /health`. Lambda in VPC reaches RDS via RDS Proxy. Stays serverless instead of an always-running Fargate service. |
| ECR repo                               | `modules/compute`  | custom    | `MUTABLE` tags, scan-on-push.                                                                                   |
| ECS Cluster (Container Insights on)    | `modules/compute`  | custom    | Single cluster.                                                                                                 |
| Fargate task definition                | `modules/compute`  | custom    | LabRole as both task and execution role (lab constraint).                                                       |
| ECS service (2 tasks, private subnets) | `modules/compute`  | custom    | `assign_public_ip = false`, `lifecycle { ignore_changes = [desired_count] }` so autoscaling owns capacity.       |
| Application Auto Scaling on queue depth | `modules/compute` | custom    | Target tracking with metric math (`messages / max(running, 1)`), step scaling fallback on raw `Visible` metric. |
| On-prem simulated VPC + CGW + Site-to-Site VPN | `modules/onprem_sim` | custom + embedded CFN | Public-only `192.168.0.0/16` VPC with one EC2 strongSwan router (deployed via `aws_cloudformation_stack` consuming `templates/vpn-gateway-strongswan.yml`). BGP-based `aws_vpn_connection` against the VGW. Gated by `var.enable_onprem_sim` (default `true`). |
| Private DNS for SQS from on-prem + queue lockdown | `modules/onprem_sim`, `modules/queue` | custom | Route 53 PHZ `sqs.<region>.amazonaws.com` associated only with the on-prem VPC (apex A record points at the SQS VPCE private IPs); static route `<aws-vpc-cidr> → strongSwan ENI` on the on-prem route table; SQS queue policy `Deny` on `sqs:SendMessage` unless `aws:VpcSourceIp` is inside the on-prem CIDR — only the on-prem site can publish. |

## 4. Data and control flow

**Ingestion and scoring:**

1. A producer (out of scope) calls `SendMessage` on the SQS main queue using the SQS Interface VPC Endpoint.
2. Fargate tasks consume from the queue, look up the user's behaviour features in DynamoDB via the DynamoDB Gateway Endpoint, run the scoring model, and publish the result to the SNS results topic via the SNS Interface VPC Endpoint.
3. Failures on the ingestion queue are retried via SQS visibility timeout. After `maxReceiveCount = 5` deliveries, the message moves to the ingestion DLQ.
4. CloudWatch Logs receives container logs through the Logs Interface Endpoint.
5. ECR holds the container image, pulled through ECR API + DKR Endpoints.
6. Application Auto Scaling reads the queue depth and the running task count and adjusts `desired_count` so the queue stays close to the target backlog per task.

**Post-analysis (fan-out from SNS):**

7. SNS delivers the fraud result to the results SQS queue (`modules/results_writer`). The SQS buffer decouples the writer Lambda from SNS and provides automatic retries (up to 3) before moving messages to the results DLQ.
8. The results-writer Lambda is triggered by the SQS event source mapping, parses the SNS envelope, and writes the fraud result to RDS PostgreSQL via RDS Proxy (`modules/data_store`).
9. The dashboard Lambda (`modules/api`) is invoked by API Gateway (`GET /transactions`) and queries RDS via RDS Proxy to serve fraud results to the dashboard client.
10. When `var.alert_email` is set, SNS also delivers directly to the email subscription — filtered to `is_fraud = true` messages only.

There is **no public ingress** to the AWS VPC. The VGW is attached and route propagation is enabled. When `var.enable_onprem_sim = true` (default), `modules/onprem_sim` provisions a separate `192.168.0.0/16` VPC with one EC2 instance running strongSwan + Quagga BGP, plus the `aws_customer_gateway` and `aws_vpn_connection` that bring up two BGP-based IPsec tunnels against the VGW. The strongSwan EC2 itself is deployed by embedding `templates/vpn-gateway-strongswan.yml` inside an `aws_cloudformation_stack`, with PSKs delivered through AWS Secrets Manager.

From the on-prem side, the SQS hostname `sqs.<region>.amazonaws.com` resolves privately to the AWS VPC's SQS Interface VPC Endpoint via a Route 53 Private Hosted Zone associated only with the on-prem VPC. A static route `<aws-vpc-cidr> → strongSwan ENI` on the on-prem route table funnels that traffic into the VPN tunnel. SQS itself rejects `sqs:SendMessage` whose `aws:VpcSourceIp` is not inside the on-prem CIDR (using `NotIpAddressIfExists`, which also denies callers that lack a VPC source IP — i.e. the public internet). The net result is that **only producers in the on-prem VPC can publish**, while Fargate consumers in the AWS VPC remain free to `ReceiveMessage` and `DeleteMessage`.

## 5. Trade-offs and explicit non-goals

- **No NAT Gateway** — saves cost and forces all egress through VPC endpoints.
- **No customer-managed KMS keys** — AWS Academy disallows KMS CMK creation. AWS-owned/managed keys are used everywhere (S3 SSE-S3, DynamoDB SSE-AWS, SQS SSE-SQS, ECR AES256). Checkov findings for this are documented and skipped on the affected resources.
- **`LabRole` as both task and execution role** — AWS Academy disallows creating new roles. Documented `CKV_AWS_249` skip on `aws_ecs_task_definition`.
- **On-prem simulation is BGP-only and single-AZ.** `modules/onprem_sim` is intentionally minimal (one public subnet, permissive SG, one EC2 router). It can be disabled with `var.enable_onprem_sim = false` to skip both the VPN connection costs and the strongSwan stack rollout.
- **No VPC Flow Logs** — intentionally skipped for the lab footprint. Re-enable later when the Checkov `CKV2_AWS_11` finding becomes a hard requirement.
- **Container image ownership.** The processor image is built in GitHub Actions, tagged with the commit SHA, pushed to ECR on `main`, and passed back into Terraform as `image_uri`; it is owned by the Fargate service in `modules/compute`. The API Dockerfile is built for CI/local validation only and is not pushed to ECR because the dashboard API runs as Lambda. The dashboard Dockerfile builds a static export instead of an ECR image; CI syncs that export to the S3 website bucket created by Terraform.
- **S3 backend with partial config.** `backend.tf` uses partial configuration; the bucket name (`itba-tp-fraud-tfstate-<account-id>`) is supplied at `terraform init` time via `-backend-config` in `make init`. DynamoDB locking is not used in the lab.

## 6. How the academic minima are met

| Requirement (from `docs/CONSIGNA.md`) | Where in this repo                                                                                              |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| ≥1 external module                    | `terraform-aws-modules/vpc/aws ~> 5.13` in `modules/network`.                                                    |
| ≥1 custom module                      | `modules/network`, `modules/queue`, `modules/data_store`, `modules/compute`, `modules/onprem_sim`, `modules/notification`, `modules/results_writer`, `modules/api`, `modules/dashboard` (9). |
| ≥4 Terraform functions                | `merge`, `format`, `cidrsubnet`, `toset`, `replace`, `length`, `can`, `cidrhost`, `jsonencode`, `contains`, `slice`. |
| ≥3 meta-arguments                     | `for_each` (gateway and interface endpoints), `lifecycle { ignore_changes }` (ECS service `desired_count`, CFN stack `pAmiId`), `depends_on` (service → SG egress rule, CFN stack → secret versions + VPN), `count` (`module.onprem_sim`), plus `validation` blocks on every variable. |
