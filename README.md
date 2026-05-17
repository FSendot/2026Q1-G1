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
| `modules/api`             | Lambda + HTTP API Gateway — endpoints `/transactions`, `/stats`, `/health`.                   |
| `modules/dashboard`       | S3 static website — fraud results dashboard (vanilla JS, no build step).                      |
| `terraform-aws-modules/vpc/aws ~> 5.13` | Base VPC, private subnets, VGW.                                             |

## Prerequisites

- Terraform ≥ 1.9 (pinned in `versions.tf`).
- AWS credentials from your AWS Academy lab session (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`).
- `make`, `pre-commit`, `tflint`, `checkov` (the `.tools/` folder bundles a couple of them).

The lab provides the IAM role `LabRole`, which the composition reuses as both ECS task and execution role.

## First-time bootstrap

The Terraform state is stored in an S3 bucket named after your AWS account ID (`terraform-state-<account-id>`). The bucket must exist before the first `terraform init` — this is a one-time step per AWS Academy account.

Since each team member has their own lab account, **everyone** must run this once:

```bash
# 1. Find your account ID and copy it to the clipboard
aws sts get-caller-identity --query Account --output text

# 2. Create the state bucket (replace <account-id> with the output above)
aws s3api create-bucket --bucket terraform-state-<account-id> --region us-east-1
aws s3api put-bucket-versioning \
  --bucket terraform-state-<account-id> \
  --versioning-configuration Status=Enabled

# 3. Initialise Terraform (starting from scratch)
terraform init -reconfigure
```

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

Build the Lambda layers (required once before the first plan):

```bash
make build-layers
```

Plan and apply:

```bash
make init
make plan         # writes tfplan; review the diff carefully
make apply        # applies the saved tfplan
```

Before building the worker container locally, run `make prepare-model`. It copies `app/net/outputs/go_runtime/model_v1/runtime_spec.json` into `app/processor/model/runtime_spec.json`, or falls back to the shared Google Drive folder when the exported spec is absent. The fallback uses only Python's standard library.

Docker deployment flow:

```bash
make init        # creates/configures the state bucket and initializes Terraform
# run the manual Apply workflow once to create ECR with the placeholder image
# run the Docker workflow manually on main to build, push, and re-apply with image_uri
```

After that bootstrap, pushes to `main` that change `app/processor/**` or `app/net/serving/go/**` build the worker image, push `${GITHUB_SHA}` and `latest` to ECR, and apply Terraform with the SHA-tagged image URI. Terraform changes alone do not trigger the Docker workflow.

After apply, get all relevant URLs:

```bash
terraform output dashboard_url   # fraud results dashboard
terraform output api_endpoint    # REST API base URL
```

Tear down at the end of the lab session:

```bash
make destroy
```

## Dashboard

The dashboard is a static web app hosted on S3 that shows real-time fraud results from the RDS database.

**Access:**

```bash
terraform output -raw dashboard_url
```

Open that URL in a browser and log in with:

| Field    | Value  |
| -------- | ------ |
| Usuario  | cloud  |
| Contraseña | cloud |

The dashboard updates automatically as the Fargate fraud processor scores transactions and publishes results to the SNS topic. Refresh the page to see new results.

## Quality gates

Run before opening a PR (also enforced by `pre-commit`):

```bash
make fmt          # terraform fmt -recursive
make validate     # terraform validate per directory
make lint         # checkov -d .
```

## Repo map

- `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `backend.tf` — root composition.
- `modules/` — reusable building blocks (`network`, `queue`, `data_store`, `compute`, `onprem_sim`, `notification`, `results_writer`, `api`, `dashboard`); each has its own `README.md`.
- `.github/workflows/docker.yml` — builds the processor image from `app/processor/Dockerfile` using `app/` as the build context and deploys the SHA-tagged image through Terraform on `main`.
- `ARCHITECTURE.md` — high-level architecture and trade-offs.
- `docs/STRUCTURE.md`, `STYLE_GUIDE.md`, `NAMING.md`, `WORKFLOW.md`, `SECURITY.md`, `CONSIGNA.md` — repo conventions and the academic brief.
- `AGENTS.md` — guardrails for AI coding agents.
- `CONTRIBUTING.md` — branching, commits, PR checklist.

## License

See `LICENSE`.
