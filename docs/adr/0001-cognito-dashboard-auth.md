# Cognito for Dashboard Authentication

The dashboard uses Amazon Cognito as the identity provider for dashboard and API access, with API Gateway performing JWT authentication before requests reach the Lambda API. The application still keeps a separate invite/access-grant record to decide who may view financial data, Google OAuth support is optional and only enabled when external Google client credentials are provided, and the bootstrap dashboard admin is created by email through an operational bootstrap script rather than managed as mutable Terraform state. Dashboard invites do not send invite emails in the lab: the bootstrap admin creates an RDS allowlist record by email, and Cognito signup/email verification proves ownership of that same email before access is activated.

The Cognito Hosted UI uses the AWS-managed Cognito domain pattern `itba-fraud-auth-<account-id>` instead of a custom domain so the lab does not require ACM or DNS setup.
