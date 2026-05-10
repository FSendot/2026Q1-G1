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

variable "principal_arn" {
  description = "ARN del rol IAM autorizado a publicar en el topic SNS. En AWS Academy se reutiliza LabRole."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/.+$", var.principal_arn))
    error_message = "principal_arn debe ser un ARN de rol IAM válido."
  }
}

variable "alert_email" {
  description = "Dirección de email para recibir alertas de fraude vía SNS (protocolo email nativo). Cuando es vacío no se crea la suscripción. SNS envía un mail de confirmación al activar."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "alert_email debe ser una dirección de correo válida o quedar vacío."
  }
}
