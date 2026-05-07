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
