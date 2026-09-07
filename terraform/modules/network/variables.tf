variable "name" {
  description = "Name prefix for every resource in this module."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Map of availability zone to CIDR block for public subnets. Keyed by AZ so that reordering does not destroy and recreate the subnets."
  type        = map(string)
}

variable "private_subnets" {
  description = "Map of availability zone to CIDR block for private subnets."
  type        = map(string)
}

variable "single_nat_gateway" {
  description = "Route all private subnets through a single NAT gateway. Cheaper, but that gateway becomes a single point of failure across AZs; false gives one NAT per AZ."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Capture VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "Retention for the flow log group. Kept short to control cost."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}