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
  description = "ARN del rol IAM autorizado a publicar, suscribir y consumir los recursos de alertas. En AWS Academy se reutiliza LabRole."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/.+$", var.principal_arn))
    error_message = "principal_arn debe ser un ARN de rol IAM válido."
  }
}

variable "vpc_id" {
  description = "ID de la VPC donde se despliega la Lambda summarizer."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs de las subnets privadas de aplicación donde se despliega la Lambda summarizer."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 1
    error_message = "Se requiere al menos 1 subnet privada."
  }
}

variable "endpoint_security_group_id" {
  description = "ID del Security Group de los Interface VPC Endpoints; la Lambda abre egress TCP/443 hacia este SG."
  type        = string
}

variable "dashboard_url" {
  description = "URL HTTPS del dashboard para enlazar desde el email de resumen de fraude."
  type        = string
  default     = ""
}

variable "summarizer_package_file" {
  description = "Ruta absoluta al paquete .zip del handler summarizer, generado desde app/notification/summarizer/handler.py en la composición raíz."
  type        = string

  validation {
    condition     = length(var.summarizer_package_file) > 0 && endswith(var.summarizer_package_file, ".zip")
    error_message = "summarizer_package_file debe ser la ruta a un archivo .zip existente."
  }
}

variable "summary_interval_minutes" {
  description = "Intervalo, en minutos, con el que se envía un resumen SNS de transacciones fraudulentas."
  type        = number
  default     = 7

  validation {
    condition     = var.summary_interval_minutes >= 1 && var.summary_interval_minutes <= 1440
    error_message = "summary_interval_minutes debe estar entre 1 y 1440."
  }
}

variable "summarizer_max_messages_per_run" {
  description = "Cantidad máxima de mensajes de fraude que la Lambda summarizer drena por ejecución."
  type        = number
  default     = 500

  validation {
    condition     = var.summarizer_max_messages_per_run >= 1 && var.summarizer_max_messages_per_run <= 1000
    error_message = "summarizer_max_messages_per_run debe estar entre 1 y 1000."
  }
}

variable "log_retention_days" {
  description = "Días de retención de los logs de la Lambda summarizer en CloudWatch Logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days debe ser un valor permitido por CloudWatch Logs."
  }
}
