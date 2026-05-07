variable "project" {
  description = "Nombre del proyecto, usado como prefijo en el nombre de la tabla DynamoDB."
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
  description = "Nombre del atributo hash key (clave de partición) de la tabla."
  type        = string
  default     = "user_id"

  validation {
    condition     = length(var.hash_key_name) > 0
    error_message = "hash_key_name no puede estar vacío."
  }
}

variable "enable_point_in_time_recovery" {
  description = "Habilita Point-In-Time Recovery sobre la tabla. Recomendado dejarlo en true para resiliencia."
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Habilita la protección contra borrado a nivel de tabla. Útil en producción; en lab puede deshabilitarse."
  type        = bool
  default     = false
}
