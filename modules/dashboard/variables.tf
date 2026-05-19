variable "project" {
  description = "Nombre del proyecto, usado como prefijo en el nombre del bucket S3."
  type        = string

  validation {
    condition     = length(var.project) > 0 && length(var.project) <= 24
    error_message = "El nombre de proyecto debe tener entre 1 y 24 caracteres."
  }
}

variable "tags" {
  description = "Tags comunes a propagar a todos los recursos creados por el módulo."
  type        = map(string)
  default     = {}
}

variable "index_html_path" {
  description = "Ruta absoluta al index.html del dashboard bajo app/."
  type        = string
}

variable "app_js_path" {
  description = "Ruta absoluta al app.js del dashboard bajo app/."
  type        = string
}

variable "config_js_template_path" {
  description = "Ruta absoluta al config.js.tpl del dashboard bajo app/."
  type        = string
}

variable "api_endpoint" {
  description = "URL base del HTTP API Gateway; se usa para crear el config.js inicial del dashboard."
  type        = string
}

variable "cognito_user_pool_id" {
  description = "ID del Cognito User Pool usado por el dashboard."
  type        = string
}

variable "cognito_client_id" {
  description = "ID del Cognito app client público usado por el dashboard."
  type        = string
}

variable "cognito_domain_url" {
  description = "URL del dominio administrado de Cognito."
  type        = string
}

variable "cognito_hosted_ui_base_url" {
  description = "URL base del Hosted UI de Cognito."
  type        = string
}

variable "cognito_issuer" {
  description = "Issuer del JWT de Cognito."
  type        = string
}

variable "cognito_redirect_uri" {
  description = "Callback URL registrada en Cognito para el dashboard."
  type        = string
}

variable "cognito_logout_uri" {
  description = "Logout URL registrada en Cognito para el dashboard."
  type        = string
}
