# FRAUD DETECTOR

Terraform repository for an AWS Academy lab.

## Quick start

Prerequisites:

- Terraform (see `versions.tf` for the pinned version)
- AWS credentials from your AWS Academy lab session
- `make`, `pre-commit`, `tflint`, `tfsec` (or `checkov`)

Bootstrap the repo:

```bash
git clone <repo-url>
cd <repo>
pre-commit install
```

Plan and apply:

```bash
make init
make plan
make apply
```

Tear down at the end of the lab session:

```bash
make destroy
```

## Repository map

- `AGENTS.md` — instructions for AI coding agents.
- `CONTRIBUTING.md` — branching, commits, PR checklist.
- `docs/STRUCTURE.md` — layout of this repo.
- `docs/STYLE_GUIDE.md` — HCL conventions.
- `docs/NAMING.md` — naming and tagging rules.
- `docs/WORKFLOW.md` — init/plan/apply flow.
- `docs/SECURITY.md` — what must never be committed.
- `modules/` — reusable building blocks.
- `scripts/` — helper scripts referenced from Terraform or used in CI.

## License

See `LICENSE`.