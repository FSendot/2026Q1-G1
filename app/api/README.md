# Dashboard API (Lambda)

Python handler for the HTTP API behind API Gateway. Deployed as `itba-tp-fraud-api` Lambda.

## Source

- `handler.py` — request routing, RDS queries, Cognito dashboard access control.

Terraform packages this file into `build/api.zip` at plan time (`lambdas.tf` at the repository root). Infrastructure lives in `modules/api/`.

## Local changes

Edit `handler.py`, then run `make plan` from the repository root so Terraform rebuilds the zip and updates the Lambda `source_code_hash`.
