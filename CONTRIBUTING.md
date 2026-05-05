## Branches

- Branch off `main` for every change. Never commit directly to `main`.
- Name pattern: `<type>/<short-description>` — e.g. `feat/vpc-module`, `fix/sg-ingress-rule`, `docs/update-naming`.
- Allowed types: `feat`, `fix`, `refactor`, `docs`, `chore`.
- Delete the branch after merging.

## Commit messages

Follow the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <short description>

[optional body]
```

- **type**: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`.
- **scope**: the affected area — e.g. `vpc`, `lambda`, `iam`, `s3`.
- **short description**: imperative mood, lowercase, no trailing period, max 72 characters.
- **body**: explain the *why*, not the *what*. Wrap at 72 characters.

Examples:

```
feat(vpc): add private subnets and NAT gateway

fix(iam): restrict S3 policy to project bucket only

docs(naming): add qualifier examples for multi-AZ resources
```

## Pull request checklist

Before opening a PR, make sure:

- [ ] Code is formatted (`make fmt`).
- [ ] Code validates (`make validate`).
- [ ] Linters pass (`make lint`).
- [ ] `terraform plan` output is attached to the PR description.
- [ ] No secrets or credentials are hardcoded.
- [ ] Variables and outputs have `description` and `type`.
- [ ] Affected module READMEs are updated.
- [ ] Relevant docs in `docs/` are updated if conventions or structure changed.
- [ ] An ADR was added under `docs/adr/` if a non-obvious design decision was made.
