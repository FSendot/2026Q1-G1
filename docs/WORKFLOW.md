# Workflow: init, plan, apply

The day-to-day flow for changing infrastructure.

## State

- This project uses a **single Terraform state** for the whole composition.
- For lab work on AWS Academy, local state may be acceptable — be aware that destroying the lab also destroys whatever is not committed (state file included if it lives only on your machine).
- If you want a more durable setup, configure a remote backend (S3 + DynamoDB) in `backend.tf`. Bootstrap that backend once, then never touch it from this composition.

## Init

Run after cloning, after any `versions.tf` change, or after pulling backend changes. Use the Make target, not raw `terraform init`, because the backend bucket is derived from the active AWS account ID and passed through `-backend-config`.

```bash
make init
```

## Plan

Always plan before applying:

```bash
make plan
```

- Save the plan output. Attach it to the PR.
- Read the diff. If anything is unexpected, stop and investigate.

## Apply

Apply only after the plan has been reviewed:

```bash
make apply
```

- Apply the **same plan** that was reviewed. Do not re-plan and apply silently.
- If the plan output changes between review and apply, stop and start over.

## Destroy

`terraform destroy` is a normal operation in lab work — use it freely to clean up between lab sessions. Just be sure that:

- You actually intend to destroy everything in the state.
- You don't have important data in stateful resources (databases, buckets) that you forgot to back up.

```bash
make destroy
```

## Drift

If someone changes infrastructure outside of Terraform:

1. Run `terraform plan` to see the drift.
2. Either bring the change into code, or revert it in the cloud. Don't leave drift hanging.

## Common pitfalls

- Forgetting to run `terraform init` after editing `versions.tf` or provider blocks.
- Running raw `terraform init` and entering an arbitrary S3 bucket. The backend bucket must be `itba-tp-fraud-tfstate-<account-id>` and is created/configured by `make init`.
- Applying a stale plan after someone else merged a change.
- Running `terraform apply` from the wrong working directory.
