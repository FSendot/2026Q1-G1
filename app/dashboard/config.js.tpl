// Configuración generada por Terraform, no editar manualmente.
window.API_BASE = ${jsonencode(api_endpoint)};
window.COGNITO_CONFIG = ${jsonencode({
  userPoolId       = cognito_user_pool_id
  clientId         = cognito_client_id
  domain           = cognito_domain_url
  domainUrl        = cognito_domain_url
  hostedUiBaseUrl  = cognito_hosted_ui_base_url
  issuer           = cognito_issuer
  redirectUri      = cognito_redirect_uri
  logoutUri        = cognito_logout_uri
})};
window.COGNITO = window.COGNITO_CONFIG;
window.AUTH_CONFIG = window.COGNITO_CONFIG;
