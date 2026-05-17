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

variable "api_endpoint" {
  description = "URL base del HTTP API Gateway; se usa para crear el config.js inicial del dashboard."
  type        = string
}
