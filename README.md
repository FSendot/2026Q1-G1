# Fraud Detector — IaC

Terraform composition that provisions an **asynchronous, serverless fraud-scoring engine** on AWS, designed to fit in a single AWS Academy lab.

The architecture is described in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## What gets created

A single composition wires five custom modules and one external module:

| Path                  | Provides                                                              |
| --------------------- | --------------------------------------------------------------------- |
| `modules/network`     | Private-only VPC, 2 AZs, VGW, gateway + interface VPC Endpoints, SG.  |
| `modules/queue`       | SQS Standard queue + DLQ + redrive + queue policies.                  |
| `modules/data_store`  | DynamoDB `<project>-user-behavior` table.                             |
| `modules/compute`     | ECR repo, ECS cluster, Fargate task + service, autoscaling on queue.  |
| `modules/onprem_sim`  | Simulated on-prem VPC + EC2 strongSwan router + CGW + Site-to-Site VPN. Toggle via `var.enable_onprem_sim` (default `true`). |
| `terraform-aws-modules/vpc/aws ~> 5.13` | Base VPC, private subnets, VGW.                     |

## Prerequisites

- Terraform ≥ 1.9 (pinned in `versions.tf`).
- AWS credentials from your AWS Academy lab session (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`).
- `make`, `pre-commit`, `tflint`, `checkov` (the `.tools/` folder bundles a couple of them).

The lab provides the IAM role `LabRole`, which the composition reuses as both ECS task and execution role.

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
- `modules/` — reusable building blocks (`network`, `queue`, `data_store`, `compute`); each has its own `README.md`.
- `ARCHITECTURE.md` — high-level architecture and trade-offs.
- `docs/STRUCTURE.md`, `STYLE_GUIDE.md`, `NAMING.md`, `WORKFLOW.md`, `SECURITY.md`, `CONSIGNA.md` — repo conventions and the academic brief.
- `AGENTS.md` — guardrails for AI coding agents.
- `CONTRIBUTING.md` — branching, commits, PR checklist.

## License

See `LICENSE`.
