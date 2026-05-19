variable "project" {
  description = "Nombre del proyecto, usado como prefijo en las colas SQS."
  type        = string
}

variable "tags" {
  description = "Tags comunes a propagar a los recursos del submódulo."
  type        = map(string)
  default     = {}
}

variable "principal_arn" {
  description = "ARN del rol IAM autorizado a enviar y consumir la cola."
  type        = string
}
