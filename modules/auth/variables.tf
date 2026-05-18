variable "project" {
  description = "Nombre del proyecto, usado como prefijo en los nombres de los recursos del módulo."
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

variable "callback_urls" {
  description = "Lista de callback URLs permitidas para el app client de Cognito. Deben incluir la URL del dashboard."
  type        = list(string)

  validation {
    condition     = length(var.callback_urls) > 0 && alltrue([for url in var.callback_urls : can(regex("^https?://", url))])
    error_message = "callback_urls debe contener al menos una URL http(s) válida."
  }
}

variable "logout_urls" {
  description = "Lista de logout URLs permitidas para el app client de Cognito."
  type        = list(string)

  validation {
    condition     = length(var.logout_urls) > 0 && alltrue([for url in var.logout_urls : can(regex("^https?://", url))])
    error_message = "logout_urls debe contener al menos una URL http(s) válida."
  }
}

variable "google_oauth_client_id" {
  description = "Client ID de Google OAuth. Dejar vacío deshabilita el IdP Google."
  type        = string
  default     = ""
}

variable "google_oauth_client_secret" {
  description = "Client secret de Google OAuth. Dejar vacío deshabilita el IdP Google."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = (var.google_oauth_client_id == "" && var.google_oauth_client_secret == "") || (var.google_oauth_client_id != "" && var.google_oauth_client_secret != "")
    error_message = "google_oauth_client_id y google_oauth_client_secret deben establecerse juntos o quedar ambos vacíos."
  }
}
