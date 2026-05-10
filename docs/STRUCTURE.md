# Repository structure

```
.
├── AGENTS.md
├── CONTRIBUTING.md
├── README.md
├── Makefile
├── .editorconfig
├── .gitignore
├── .pre-commit-config.yaml
├── .tflint.hcl
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
├── backend.tf
├── terraform.tfvars.example
├── ARCHITECTURE.md
├── docs/
│   ├── STRUCTURE.md
│   ├── STYLE_GUIDE.md
│   ├── NAMING.md
│   ├── WORKFLOW.md
│   ├── SECURITY.md
│   └── CONSIGNA.md
├── modules/
│   ├── network/          # VPC, subnets, VGW, VPC Endpoints (S3, DynamoDB, SQS, ECR, Logs, SNS)
│   ├── queue/            # SQS transaction queue + DLQ (ingestion side)
│   ├── data_store/       # DynamoDB user-behavior table + RDS PostgreSQL fraud results
│   ├── compute/          # ECR, ECS Cluster, Fargate service, Application Auto Scaling
│   ├── onprem_sim/       # On-prem VPC simulation: strongSwan EC2, CGW, Site-to-Site VPN
│   ├── notification/     # SNS results topic + optional email subscription (fan-out hub)
│   ├── results_writer/   # SQS results queue + Lambda writer (SNS → SQS → Lambda → RDS)
│   └── api/              # Lambda + HTTP API Gateway (dashboard: GET /transactions)
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── README.md
└── scripts/
```

## Rules

- The root is the **single Terraform composition** for the project. It wires modules together and configures the provider and backend.
- **`modules/`** contains reusable building blocks. A module = one logical unit of infrastructure.
- Every module has its own `README.md` documenting inputs, outputs, and example usage.
- Every module has a `versions.tf` pinning Terraform and provider versions.
- Keep root resource declarations to a minimum: prefer composing modules over inlining resources.
- `scripts/` holds helper shell scripts, bootstrap files, or templates referenced from Terraform. Treat them as code: review them, keep them small.

## Adding a new module

1. Create `modules/<name>/` with the five required files.
2. Document inputs and outputs in `modules/<name>/README.md` (use `terraform-docs` to keep it in sync).
3. Wire it into the root `main.tf`.
4. Run linters and add the plan to your PR.

## What does *not* go in this repo

- Application source code.
- Long-lived secrets (use AWS Secrets Manager or Parameter Store).
- Personal tooling (keep that in your dotfiles).
