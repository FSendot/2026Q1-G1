# HCL style guide

Conventions for Terraform code in this repo. When in doubt, follow `terraform fmt`.

## Files

- One concern per file. Split `main.tf` if it grows past ~200 lines.
- Standard files in every module:
  - `main.tf` — resources and module calls
  - `variables.tf` — input variables
  - `outputs.tf` — outputs
  - `versions.tf` — Terraform and provider version constraints
  - `README.md` — generated docs

## Formatting

- Run `terraform fmt -recursive` before committing.
- 2-space indentation. No tabs.
- Trailing newline at the end of every file.

## Variables

- Always set `type` and `description`.
- Use `default` only when there is a sensible, safe default.
- Validate inputs with `validation` blocks for non-trivial constraints.

```hcl
variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}
```

## Outputs

- Always set `description`.
- Mark sensitive outputs with `sensitive = true`.
- Output what consumers actually need, not your entire resource.

## Locals

- Use `locals` for computed values reused in multiple places.
- Keep local names short and meaningful.

```hcl
locals {
  common_tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
```

## Resources

- Resource names: `snake_case`, singular, descriptive of role rather than physical thing.
  - Good: `resource "aws_s3_bucket" "logs"`
  - Bad: `resource "aws_s3_bucket" "my_bucket_1"`
- Always set `tags = local.common_tags` (merged with resource-specific tags as needed).

## Modules

- Module calls go in the root `main.tf` (or split into topical files).
- Pin module sources to a tag or commit SHA, not a branch.
- Pass only what the module needs; don't forward the entire variable surface.

## Comments

- Prefer self-explanatory code over comments.
- When you must comment, explain *why*, not *what*.

## Anti-patterns to avoid

- Using `count` to toggle a single resource. Prefer `for_each` with a map, or split into modules.
- Computing IAM policies inline in `main.tf`. Use `data "aws_iam_policy_document"`.
- Storing secrets in `terraform.tfvars`. Use a secret manager or environment variables.
