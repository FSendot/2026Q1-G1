# `modules/dashboard`

Provisions the S3 static website bucket used by the fraud dashboard. Terraform owns the bucket, website configuration, public-read policy for the lab, bootstrap object keys, and outputs. CI builds `app/dashboard/Dockerfile` and syncs the exported files to this Terraform-created bucket.

## Resources

- `aws_s3_bucket.dashboard` — `<project>-dashboard`, force-destroy enabled for the short-lived lab.
- `aws_s3_bucket_website_configuration.dashboard` — static website hosting with `index.html`.
- `aws_s3_bucket_public_access_block.dashboard` — public access block relaxed for the public website endpoint.
- `aws_s3_bucket_policy.dashboard` — allows public `s3:GetObject` on website objects.
- `aws_s3_object.index_html`, `aws_s3_object.app_js`, `aws_s3_object.config_js` — bootstrap dashboard objects. Their content is ignored after creation so CI can publish the built frontend without causing Terraform artifact drift.

## Inputs

| Name      | Type          | Default | Description                                      |
| --------- | ------------- | ------- | ------------------------------------------------ |
| `project` | `string`      | n/a     | Prefix for the dashboard bucket name.            |
| `api_endpoint` | `string` | n/a | API Gateway endpoint used for the bootstrap `config.js`. |
| `tags`    | `map(string)` | `{}`    | Common tags merged with `Component = "dashboard"`. |

## Outputs

| Name          | Description                                      |
| ------------- | ------------------------------------------------ |
| `website_url` | S3 website endpoint URL for the dashboard.       |
| `bucket_name` | Bucket name where CI syncs the frontend export.  |

## Deployment

The Docker workflow builds the dashboard export with the current API Gateway endpoint:

```bash
docker build \
  -f app/dashboard/Dockerfile \
  --target export \
  --build-arg "API_BASE=$(terraform output -raw api_endpoint)" \
  --output type=local,dest=dashboard-dist \
  app

aws s3 sync dashboard-dist "s3://$(terraform output -raw dashboard_bucket_name)/" --delete
```
