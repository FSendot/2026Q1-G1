# AGENTS.md

This file is the entry point for AI coding agents (Claude, Cursor, Copilot, etc.) working on this repository. Read it fully before making changes.

## What this repo is

A Terraform repository that provisions AWS infrastructure for an academic lab on AWS Academy. Single composition, single state, short-lived.

## Ground rules

- **Plan before apply.** Always run `terraform plan` and review the diff before any `apply`.
- **Never apply without human review** unless explicitly asked. Surface the plan and wait.
- **Small, focused changes.** Prefer many small PRs over one big one.
- **Idempotent code.** Re-running `terraform apply` with no input changes must produce no diff.
- **Reproducible.** Anything you change in the cloud must also be in code. No console clicks.

## Before editing

1. Read `docs/STRUCTURE.md` to understand the layout.
2. Read `docs/STYLE_GUIDE.md` for HCL conventions.
3. Read `docs/NAMING.md` for naming and tagging rules.
4. Read `docs/WORKFLOW.md` for init/plan/apply flow.
5. Read `docs/SECURITY.md` for what must never be committed.

## What you can do

- Add or modify modules under `modules/`.
- Adjust the root composition (`main.tf`, `variables.tf`, `outputs.tf`).
- Update documentation when behavior changes.
- Add tests, examples, or linters.

## What you must never do

- Hardcode account IDs, ARNs, or region names.
- Hardcode secrets, tokens, or credentials. Ever.
- Bypass the module boundary (do not edit a module's outputs from outside the module).
- Run `terraform apply -auto-approve` outside of an explicitly approved automation context.
- Delete state files or run `terraform state rm` without a written plan.

## Tooling expected to be available

- `terraform` (version pinned in `versions.tf`)
- `tflint`
- `tfsec` or `checkov`
- `pre-commit`
- `make`

## When in doubt

- Open a draft PR with the plan output and ask.
- If a change is risky (IAM, networking, data stores), tag a human reviewer.
- Prefer documentation over assumption: if a convention is unclear, propose an update to the relevant doc in the same PR.