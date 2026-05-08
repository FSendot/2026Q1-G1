variable "project" {
  description = "Nombre del proyecto, usado como prefijo en los nombres de los recursos provisionados por el módulo."
  type        = string

  validation {
    condition     = length(var.project) > 0 && length(var.project) <= 24
    error_message = "El nombre de proyecto debe tener entre 1 y 24 caracteres para que los nombres derivados respeten los límites de AWS."
  }
}

variable "vpn_gateway_id" {
  description = "ID del Virtual Private Gateway al que se conecta la VPN site-to-site (proviene del módulo network)."
  type        = string

  validation {
    condition     = length(var.vpn_gateway_id) > 0
    error_message = "vpn_gateway_id no puede estar vacío; debe ser un ID válido de Virtual Private Gateway."
  }
}

variable "aws_vpc_cidr" {
  description = "CIDR de la VPC del lado AWS, usado para autorizar tráfico desde la VPN en el Security Group del router on-premise."
  type        = string

  validation {
    condition     = can(cidrhost(var.aws_vpc_cidr, 0))
    error_message = "aws_vpc_cidr debe ser un bloque CIDR IPv4 válido."
  }
}

variable "azs" {
  description = "Lista de Availability Zones disponibles. Sólo se usa la primera para alojar la subnet pública del on-premise simulado."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 1
    error_message = "Se requiere al menos una Availability Zone para crear la subnet pública del on-premise simulado."
  }
}

variable "onprem_vpc_cidr" {
  description = "Bloque CIDR de la VPC simulada de on-premise. Debe no solaparse con la VPC del lado AWS."
  type        = string
  default     = "192.168.0.0/16"

  validation {
    condition     = can(cidrhost(var.onprem_vpc_cidr, 0))
    error_message = "onprem_vpc_cidr debe ser un bloque CIDR IPv4 válido."
  }
}

variable "onprem_public_subnet_cidr" {
  description = "Bloque CIDR de la subnet pública on-premise donde corre el EC2 strongSwan."
  type        = string
  default     = "192.168.1.0/24"

  validation {
    condition     = can(cidrhost(var.onprem_public_subnet_cidr, 0))
    error_message = "onprem_public_subnet_cidr debe ser un bloque CIDR IPv4 válido."
  }
}

variable "instance_type" {
  description = "Tipo de instancia EC2 para el VPN gateway strongSwan. Restringido a los valores aceptados por la plantilla CloudFormation."
  type        = string
  default     = "t3a.micro"

  validation {
    condition     = contains(["t3a.micro", "t3a.small", "t3a.medium"], var.instance_type)
    error_message = "instance_type debe ser uno de t3a.micro, t3a.small o t3a.medium (valores permitidos por templates/vpn-gateway-strongswan.yml)."
  }
}

variable "tags" {
  description = "Tags comunes a propagar a todos los recursos creados por el módulo (mergeados con tags específicos)."
  type        = map(string)
  default     = {}
}
