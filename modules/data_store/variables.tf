variable "project" {
  description = "Nombre del proyecto, usado como prefijo en los nombres de los recursos del módulo."
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

variable "hash_key_name" {
  description = "Nombre del atributo hash key (clave de partición) de la tabla DynamoDB de comportamiento de usuario."
  type        = string
  default     = "user_id"

  validation {
    condition     = length(var.hash_key_name) > 0
    error_message = "hash_key_name no puede estar vacío."
  }
}

variable "enable_point_in_time_recovery" {
  description = "Habilita Point-In-Time Recovery sobre la tabla DynamoDB."
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Habilita la protección contra borrado a nivel de tabla DynamoDB. En lab puede deshabilitarse."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "ID de la VPC donde se despliega la instancia RDS."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs de las subnets privadas que forman el DB subnet group. Se requieren al menos 2 AZs."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Se requieren al menos 2 subnets en distintas AZs para el DB subnet group."
  }
}

variable "instance_class" {
  description = "Clase de instancia RDS. En lab académico se recomienda db.t3.micro para minimizar costo."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos inicial creada en la instancia PostgreSQL."
  type        = string
  default     = "fraud_results"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.db_name))
    error_message = "db_name debe comenzar con letra y contener sólo letras, números y guiones bajos."
  }
}

variable "db_username" {
  description = "Nombre del usuario master de la instancia PostgreSQL."
  type        = string
  default     = "fraud_admin"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.db_username))
    error_message = "db_username debe comenzar con letra y contener sólo letras, números y guiones bajos."
  }
}

variable "db_password" {
  description = "Contraseña del usuario master. Marcada como sensitive; se recomienda generarla con random_password en la composición raíz."
  type        = string
  sensitive   = true
}

variable "principal_arn" {
  description = "ARN del rol IAM que el proxy utiliza para leer las credenciales de Secrets Manager (en AWS Academy, siempre LabRole)."
  type        = string
}
