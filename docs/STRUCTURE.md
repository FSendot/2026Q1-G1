# Repository structure

```
.
├── AGENTS.md
├── CONTEXT.md
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
│   ├── CONSIGNA.md
│   └── adr/
├── modules/
│   ├── auth/             # Cognito User Pool, Hosted UI domain, optional Google IdP
│   ├── network/          # VPC, subnets, VGW, VPC Endpoints (S3, DynamoDB, SQS, ECR, Logs, SNS)
│   ├── queue/            # SQS transaction queue + DLQ (ingestion side)
│   ├── data_store/       # DynamoDB user-behavior table + RDS PostgreSQL fraud results
│   ├── compute/          # ECR, ECS Cluster, Fargate service, Application Auto Scaling
│   ├── onprem_sim/       # On-prem VPC simulation: strongSwan EC2, CGW, Site-to-Site VPN
│   ├── notification/     # Fraud-alert summary composition: SNS topic, SQS queue, scheduled summarizer Lambda
│   ├── results_writer/   # SQS results queue + Lambda writer (processor → SQS → Lambda → RDS)
│   └── api/              # Lambda + HTTP API Gateway (Cognito-protected dashboard API)
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── README.md
├── app/
│   ├── processor/        # Fraud worker container deployed to ECS Fargate
│   ├── notification/     # Fraud-summary Lambda application code packaged by Terraform
│   ├── api/              # Dashboard API source + Docker build check; Terraform deploys Lambda zip
│   ├── dashboard/        # Static frontend export deployed to the dashboard S3 bucket
│   └── net/              # Local ML pipeline; not deployed, except serving/go used by processor builds
└── scripts/
```

## Rules

- The root is the **single Terraform composition** for the project. It wires modules together and configures the provider and backend.
- **`modules/`** contains reusable building blocks. A module = one logical unit of infrastructure.
- Every module has its own `README.md` documenting inputs, outputs, and example usage.
- Every module has a `versions.tf` pinning Terraform and provider versions.
- `CONTEXT.md` defines domain language used by auth and dashboard access-control work.
- `docs/adr/` records architecture decisions that are costly or surprising to reverse.
- Keep root resource declarations to a minimum: prefer composing modules over inlining resources.
- `app/` holds the small lab services, Lambda handlers, and Dockerfiles. Keep `app/net` out of cloud deployment; only `app/net/serving/go` is part of the processor build context. Only Docker images consumed by Fargate are pushed to ECR.
- `scripts/` holds helper shell scripts, bootstrap files, or templates referenced from Terraform. Treat them as code: review them, keep them small.

## Adding a new module

1. Create `modules/<name>/` with the five required files.
2. Document inputs and outputs in `modules/<name>/README.md` (use `terraform-docs` to keep it in sync).
3. Wire it into the root `main.tf`.
4. Run linters and add the plan to your PR.

## What does *not* go in this repo

- Application source code unrelated to the lab deployment contract.
- Long-lived secrets (use AWS Secrets Manager or Parameter Store).
- Personal tooling (keep that in your dotfiles).
