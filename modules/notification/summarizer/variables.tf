variable "project" {
  description = "Nombre del proyecto, usado como prefijo en los recursos de la Lambda."
  type        = string
}

variable "tags" {
  description = "Tags comunes a propagar a los recursos del submódulo."
  type        = map(string)
  default     = {}
}

variable "principal_arn" {
  description = "ARN del rol IAM usado como execution role de la Lambda summarizer."
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC donde se despliega la Lambda summarizer."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs de las subnets privadas donde se despliega la Lambda summarizer."
  type        = list(string)
}

variable "endpoint_security_group_id" {
  description = "ID del Security Group de los Interface VPC Endpoints."
  type        = string
}

variable "fraud_alert_queue_url" {
  description = "URL de la cola SQS de alertas de fraude."
  type        = string
}

variable "summary_topic_arn" {
  description = "ARN del topic SNS donde se publican los resúmenes."
  type        = string
}

variable "summary_interval_minutes" {
  description = "Intervalo, en minutos, para publicar resúmenes."
  type        = number
}

variable "summarizer_max_messages_per_run" {
  description = "Cantidad máxima de mensajes que la Lambda drena por ejecución."
  type        = number
}

variable "log_retention_days" {
  description = "Días de retención de logs de CloudWatch."
  type        = number
}
