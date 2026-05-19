# Results Writer

Go Lambda application that drains the results SQS queue and writes scoring results to PostgreSQL through the RDS Proxy.

The Terraform infrastructure lives in `modules/results_writer`. This directory owns only runtime code and tests.

Build from the repository root:

```bash
make build-results-writer
```

The build creates `app/results_writer/build/results-writer.zip` with a `bootstrap` executable at the zip root for the Lambda `provided.al2023` runtime.

Normal `make plan`, `make validate`, and CI Terraform workflows build this package before Terraform hashes it. Run the build target manually when calling Terraform directly.
