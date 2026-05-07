variable "project" {
  description = "Nombre del proyecto, usado como prefijo en los nombres de los recursos provisionados por el módulo."
  type        = string

  validation {
    condition     = length(var.project) > 0 && length(var.project) <= 24
    error_message = "El nombre de proyecto debe tener entre 1 y 24 caracteres para que los nombres derivados respeten los límites de AWS."
  }
}

variable "vpc_cidr" {
  description = "Bloque CIDR principal de la VPC. Se subdivide en subnets privadas con cidrsubnet()."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr debe ser un bloque CIDR IPv4 válido."
  }
}

variable "azs" {
  description = "Lista de Availability Zones donde se crean subnets privadas. Se requieren al menos dos para alta disponibilidad."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Se requieren al menos 2 Availability Zones para que el servicio ECS quede multi-AZ."
  }
}

variable "tags" {
  description = "Tags comunes a propagar a todos los recursos creados por el módulo (mergeados con tags específicos)."
  type        = map(string)
  default     = {}
}
