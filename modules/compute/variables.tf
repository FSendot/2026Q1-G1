variable "project" {
  description = "Nombre del proyecto, usado como prefijo en los nombres de los recursos de cómputo."
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

variable "vpc_id" {
  description = "ID de la VPC donde corre el servicio ECS."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs de las subnets privadas donde se programan las tasks de Fargate."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Se requieren al menos 2 subnets privadas para alta disponibilidad."
  }
}

variable "endpoint_security_group_id" {
  description = "ID del Security Group asociado a los Interface VPC Endpoints; las tasks abren egress únicamente hacia este SG en tcp/443."
  type        = string
}

variable "task_role_arn" {
  description = "ARN del rol IAM asignado al contenedor (task role). En AWS Academy se reutiliza LabRole."
  type        = string
}

variable "execution_role_arn" {
  description = "ARN del rol IAM utilizado por el agente ECS para pullear imágenes y publicar logs (execution role). En AWS Academy se reutiliza LabRole."
  type        = string
}

variable "image_uri" {
  description = "URI completa de la imagen de contenedor (incluye etiqueta o digest). Si está vacía, se usa una imagen placeholder hasta que la imagen real sea publicada."
  type        = string
  default     = ""
}

variable "task_cpu" {
  description = "CPU asignada a cada task de Fargate, expresada en unidades del task definition (1024 = 1 vCPU)."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.task_cpu)
    error_message = "task_cpu debe ser uno de los valores soportados por Fargate: 256, 512, 1024, 2048, 4096."
  }
}

variable "task_memory" {
  description = "Memoria asignada a cada task de Fargate, en MiB."
  type        = number
  default     = 1024

  validation {
    condition     = var.task_memory >= 512 && var.task_memory <= 30720
    error_message = "task_memory debe estar entre 512 y 30720 MiB."
  }
}

variable "desired_count" {
  description = "Cantidad inicial de tasks que el servicio ECS mantiene corriendo."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count no puede ser negativo."
  }
}

variable "min_capacity" {
  description = "Cantidad mínima de tasks que el autoscaling puede mantener en el servicio."
  type        = number
  default     = 1

  validation {
    condition     = var.min_capacity >= 0
    error_message = "min_capacity no puede ser negativo."
  }
}

variable "max_capacity" {
  description = "Cantidad máxima de tasks que el autoscaling puede levantar ante picos de carga."
  type        = number
  default     = 10

  validation {
    condition     = var.max_capacity >= 1
    error_message = "max_capacity debe ser al menos 1."
  }
}

variable "processor_concurrency" {
  description = "Cantidad de workers concurrentes por task para procesar mensajes SQS."
  type        = number
  default     = 32

  validation {
    condition     = var.processor_concurrency >= 1 && var.processor_concurrency <= 512
    error_message = "processor_concurrency debe estar entre 1 y 512."
  }
}

variable "processor_pollers" {
  description = "Cantidad de pollers SQS concurrentes por task."
  type        = number
  default     = 4

  validation {
    condition     = var.processor_pollers >= 1 && var.processor_pollers <= 64
    error_message = "processor_pollers debe estar entre 1 y 64."
  }
}

variable "queue_arn" {
  description = "ARN de la cola SQS principal; usado por el target tracking del autoscaling."
  type        = string
}

variable "queue_url" {
  description = "URL de la cola SQS principal; pasada como variable de entorno al contenedor."
  type        = string
}

variable "queue_name" {
  description = "Nombre de la cola SQS principal; usado en la métrica CloudWatch para autoscaling."
  type        = string
}

variable "table_name" {
  description = "Nombre de la tabla DynamoDB de comportamiento de usuario; pasada como variable de entorno al contenedor."
  type        = string
}

variable "results_queue_url" {
  description = "URL de la cola SQS donde el contenedor publica todos los resultados de scoring."
  type        = string
}

variable "fraud_alert_queue_url" {
  description = "URL de la cola SQS donde el contenedor publica sólo resultados fraudulentos para resumen."
  type        = string
}

variable "audit_bucket_name" {
  description = "Nombre del bucket S3 donde el contenedor escribe el audit log de cada transacción procesada; pasado como variable de entorno S3_AUDIT_BUCKET."
  type        = string
}

variable "log_retention_days" {
  description = "Cantidad de días que se retienen los logs del contenedor en CloudWatch Logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days debe ser un valor permitido por CloudWatch Logs."
  }
}

variable "scaling_target_messages_per_task" {
  description = "Cantidad de mensajes visibles por task que el autoscaling intenta sostener (target tracking)."
  type        = number
  default     = 10

  validation {
    condition     = var.scaling_target_messages_per_task > 0
    error_message = "scaling_target_messages_per_task debe ser mayor a 0."
  }
}
