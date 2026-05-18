# `modules/auth`

Provisions the Cognito auth slice for the dashboard: a user pool with email sign-in and self-sign-up, an AWS-managed hosted UI domain, a public app client, and an optional Google identity provider.

## Resources

- `aws_cognito_user_pool.this` - Cognito user pool with email as the sign-in alias, email verification, and verified-email account recovery.
- `aws_cognito_identity_provider.google` - Optional Google IdP when both Google OAuth variables are set.
- `aws_cognito_user_pool_domain.this` - AWS-managed hosted UI domain with the fixed `itba-fraud-auth-<account-id>` prefix.
- `aws_cognito_user_pool_client.this` - Public app client with auth code flow, no client secret, and callback/logout URLs supplied by the root composition.

## Inputs

| Name                        | Type           | Default | Description |
| --------------------------- | -------------- | ------- | ----------- |
| `project`                   | `string`       | n/a     | Prefix for the user pool and app client names. |
| `tags`                      | `map(string)`  | `{}`    | Common tags merged with `Component = "auth"`. |
| `callback_urls`             | `list(string)` | n/a     | Allowed Cognito callback URLs. |
| `logout_urls`               | `list(string)` | n/a     | Allowed Cognito logout URLs. |
| `google_oauth_client_id`    | `string`       | `""`    | Optional Google OAuth client ID. |
| `google_oauth_client_secret`| `string`       | `""`    | Optional Google OAuth client secret. |

## Outputs

| Name               | Description |
| ------------------ | ----------- |
| `user_pool_id`     | Cognito user pool ID. |
| `client_id`        | Public app client ID. |
| `domain_url`       | Managed Cognito domain URL. |
| `hosted_ui_base_url` | Hosted UI authorize endpoint base URL. |
| `issuer`           | JWT issuer URL for API Gateway authorizers. |
