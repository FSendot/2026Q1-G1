# Security

Rules for keeping credentials and sensitive data out of this repository.

## Never commit

- AWS access keys, session tokens, or `~/.aws/credentials`.
- The `labsuser.pem` (or equivalent) key file from your AWS Academy lab session.
- API tokens, OAuth client secrets, or third-party service credentials.
- Database passwords or connection strings with credentials embedded.
- Private TLS keys, SSH private keys, or signing keys.
- `.env` files containing secrets.
- `terraform.tfstate` or `terraform.tfstate.backup`.

The `.gitignore` already blocks the obvious cases — do not work around it.

## How to handle secrets

- **At runtime in AWS:** AWS Secrets Manager or SSM Parameter Store (SecureString). Read from Terraform via `data` sources.
- **For local development:** environment variables, or a `.env` file that is git-ignored.
- **For CI:** the CI provider's secret store. Inject as environment variables.

## AWS credentials in the lab

- AWS Academy lab sessions provide short-lived credentials. Refresh them when the session expires.
- Do not paste lab credentials into chat, issues, or PR descriptions.
- Use the lab-provided `LabRole` and `LabInstanceProfile` for workloads that need IAM. Do not try to create new IAM roles or users — the lab restricts that.

## Sensitive variables

- Mark Terraform variables holding secrets with `sensitive = true`.
- Mark outputs that surface secrets with `sensitive = true`.
- Do not log sensitive values in `null_resource` or `local-exec` provisioners.

## State

- Treat `terraform.tfstate` as sensitive — it contains every resource attribute, including some secrets.
- If using local state, do not share it. If using a remote backend, ensure the bucket is private and encrypted.

## If a secret leaks

1. Rotate the secret immediately at the source (AWS, GitHub, etc.).
2. Remove it from the repo history (`git filter-repo` or BFG). A plain commit revert is not enough.
3. Tell the team.