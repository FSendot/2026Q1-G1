# Fraud Detector — IaC

Terraform composition that provisions an **asynchronous, serverless fraud-scoring engine** on AWS, designed to fit in a single AWS Academy lab.

The architecture is described in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## What gets created

A single composition wires eight custom modules and one external module:

| Path                      | Provides                                                                                      |
| ------------------------- | --------------------------------------------------------------------------------------------- |
| `modules/network`         | Private-only VPC, 2 AZs, VGW, gateway + interface VPC Endpoints (incl. SNS), SG.             |
| `modules/queue`           | SQS transaction queue + DLQ + redrive + queue policies (ingestion side).                      |
| `modules/data_store`      | DynamoDB `user-behavior` table + RDS PostgreSQL `fraud-results` DB.                           |
| `modules/compute`         | ECR repo, ECS cluster, Fargate task + service, autoscaling on queue depth.                    |
| `modules/onprem_sim`      | Simulated on-prem VPC + EC2 strongSwan + CGW + Site-to-Site VPN. Toggle via `var.enable_onprem_sim`. |
| `modules/notification`    | SNS results topic + optional email subscription for fraud alerts.                             |
| `modules/results_writer`  | SQS results queue + DLQ + Lambda writer (SNS → SQS → Lambda → RDS).                          |
| `modules/api`             | Lambda + HTTP API Gateway — dashboard endpoint `GET /transactions`.                           |
| `terraform-aws-modules/vpc/aws ~> 5.13` | Base VPC, private subnets, VGW.                                             |

## Prerequisites

- Terraform ≥ 1.9 (pinned in `versions.tf`).
- AWS credentials from your AWS Academy lab session (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`).
- `make`, `pre-commit`, `tflint`, `checkov` (the `.tools/` folder bundles a couple of them).

The lab provides the IAM role `LabRole`, which the composition reuses as both ECS task and execution role.

## First-time bootstrap

The Terraform state is stored in an S3 bucket (`itba-tp-fraud-tfstate`). The bucket must exist before the first `terraform init`. This is a one-time step per AWS account — once created, all team members share the same bucket.

```bash
aws s3api create-bucket --bucket itba-tp-fraud-tfstate --region us-east-1
aws s3api put-bucket-versioning \
  --bucket itba-tp-fraud-tfstate \
  --versioning-configuration Status=Enabled
terraform init -migrate-state   # migrates any existing local state to S3
```

If you are starting from scratch with no prior local state, `terraform init` (without `-migrate-state`) is enough.

> **GitHub Actions** (plan / apply workflows) create the bucket automatically if it does not exist. No manual step is needed when running through CI.

## Run-book

```bash
git clone <repo-url>
cd fraud-detector-terraform
pre-commit install
```

Set up your `terraform.tfvars` from the example:

```bash
cp terraform.tfvars.example terraform.tfvars
# adjust capacity values if needed
```

Plan and apply:

```bash
make init
make plan         # writes tfplan; review the diff carefully
make apply        # applies the saved tfplan
```

Tear down at the end of the lab session:

```bash
make destroy
```

## Quality gates

Run before opening a PR (also enforced by `pre-commit`):

```bash
make fmt          # terraform fmt -recursive
make validate     # terraform validate per directory
make lint         # checkov -d .
```

## Repo map

- `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `backend.tf` — root composition.
- `modules/` — reusable building blocks (`network`, `queue`, `data_store`, `compute`, `onprem_sim`, `notification`, `results_writer`, `api`); each has its own `README.md`.
- `ARCHITECTURE.md` — high-level architecture and trade-offs.
- `docs/STRUCTURE.md`, `STYLE_GUIDE.md`, `NAMING.md`, `WORKFLOW.md`, `SECURITY.md`, `CONSIGNA.md` — repo conventions and the academic brief.
- `AGENTS.md` — guardrails for AI coding agents.
- `CONTRIBUTING.md` — branching, commits, PR checklist.

## License

See `LICENSE`.
