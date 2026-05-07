variable "project" {
  description = "Nombre del proyecto, usado como prefijo en los nombres de las colas SQS."
  type        = string

  validation {
    condition     = length(var.project) > 0 && length(var.project) <= 24
    error_message = "El nombre de proyecto debe tener entre 1 y 24 caracteres."
  }
}

variable "tags" {
  description = "Tags comunes a propagar a todos los recursos creados por el módulo (mergeados con tags específicos)."
  type        = map(string)
  default     = {}
}

variable "principal_arn" {
  description = "ARN del principal (rol IAM) autorizado a producir y consumir mensajes en la cola principal."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/.+$", var.principal_arn))
    error_message = "principal_arn debe ser un ARN de rol IAM válido (arn:aws:iam::<account>:role/<name>)."
  }
}

variable "max_receive_count" {
  description = "Cantidad máxima de recepciones de un mensaje antes de moverlo al DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count debe estar entre 1 y 1000."
  }
}

variable "visibility_timeout_seconds" {
  description = "Visibility timeout de la cola principal, en segundos. Debe superar el peor caso de procesamiento del consumer."
  type        = number
  default     = 60

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds debe estar entre 0 y 43200 (12 horas)."
  }
}

variable "message_retention_seconds" {
  description = "Tiempo (en segundos) que un mensaje permanece en la cola principal antes de ser descartado."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds debe estar entre 60 y 1209600 (14 días)."
  }
}

variable "dlq_message_retention_seconds" {
  description = "Tiempo (en segundos) que un mensaje permanece en el DLQ. Suele ser el máximo (14 días) para análisis de fallos."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dlq_message_retention_seconds >= 60 && var.dlq_message_retention_seconds <= 1209600
    error_message = "dlq_message_retention_seconds debe estar entre 60 y 1209600 (14 días)."
  }
}
