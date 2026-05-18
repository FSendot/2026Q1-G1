variable "image_uri" {
  description = "URI completa de la imagen de contenedor que ejecuta el scoring de fraude (incluye etiqueta o digest). El push de la imagen ocurre fuera de Terraform."
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
  description = "Cantidad de workers concurrentes por task de Fargate para procesar mensajes SQS."
  type        = number
  default     = 32

  validation {
    condition     = var.processor_concurrency >= 1 && var.processor_concurrency <= 512
    error_message = "processor_concurrency debe estar entre 1 y 512."
  }
}

variable "processor_pollers" {
  description = "Cantidad de long-pollers SQS concurrentes por task de Fargate."
  type        = number
  default     = 4

  validation {
    condition     = var.processor_pollers >= 1 && var.processor_pollers <= 64
    error_message = "processor_pollers debe estar entre 1 y 64."
  }
}

variable "enable_onprem_sim" {
  description = "Habilita la VPC simulada de on-premise con su EC2 strongSwan, Customer Gateway, conexión Site-to-Site VPN contra el VGW, la Private Hosted Zone para SQS y el lockdown de la cola al CIDR on-premise."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Dirección de email para recibir alertas de fraude vía SNS (protocolo email nativo de SNS). Cuando es vacío no se crea la suscripción. SNS envía un mail de confirmación al activar; el destinatario debe aceptarlo antes de recibir alertas."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "alert_email debe ser una dirección de correo válida o quedar vacío."
  }
}

variable "google_oauth_client_id" {
  description = "Client ID de Google OAuth para habilitar el IdP opcional en Cognito. Dejar vacío deshabilita Google."
  type        = string
  default     = ""
}

variable "google_oauth_client_secret" {
  description = "Client secret de Google OAuth para habilitar el IdP opcional en Cognito. Dejar vacío deshabilita Google."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = (var.google_oauth_client_id == "" && var.google_oauth_client_secret == "") || (var.google_oauth_client_id != "" && var.google_oauth_client_secret != "")
    error_message = "google_oauth_client_id y google_oauth_client_secret deben establecerse juntos o quedar ambos vacíos."
  }
}
