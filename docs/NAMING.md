# Naming and tagging

Consistent names and tags make resources easy to find, audit, and clean up.

## Resource names (Terraform identifiers)

- `snake_case`.
- Singular nouns describing the role: `web`, `api`, `db`, `vpc`, `logs`.
- No environment, account, or region in the Terraform identifier — that belongs in the cloud-side name and in tags.

Good:

```hcl
resource "aws_security_group" "web" { ... }
resource "aws_db_instance"     "primary" { ... }
```

Bad:

```hcl
resource "aws_security_group" "my_sg_1" { ... }
resource "aws_db_instance"     "the_database" { ... }
```

## Cloud-side names

Use a consistent pattern when naming AWS resources:

```
<project>-<role>[-<qualifier>]
```

Examples:

- `myproj-web-alb`
- `myproj-api-asg`
- `myproj-data-bucket-01`

Keep it lowercase. Use hyphens, not underscores (some AWS resources reject underscores).

## Required tags

Every taggable resource gets at least:

| Tag         | Example       | Notes                                      |
| ----------- | ------------- | ------------------------------------------ |
| `Project`   | `myproj`      | The project this resource belongs to.      |
| `ManagedBy` | `terraform`   | Always `terraform` for resources in code.  |

## Optional but encouraged

- `Component` — logical component (e.g. `networking`, `data`, `web`).
- `Repo` — repository URL or short name, useful for cross-repo audits.
- `Tier` — `public`, `private`, `data`, etc.

## How to apply tags

Define a `local.common_tags` in the root and pass it down to modules:

```hcl
locals {
  common_tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

module "network" {
  source = "./modules/network"
  tags   = local.common_tags
}
```

Inside modules, merge any resource-specific tags:

```hcl
resource "aws_s3_bucket" "logs" {
  bucket = "${var.project}-logs"
  tags   = merge(var.tags, { Component = "logging" })
}
```