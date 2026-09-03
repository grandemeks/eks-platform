variable "project" {
  description = "Short project name used as a prefix for every resource name."
  type        = string
  default     = "eks-platform"
}

variable "environment" {
  description = "Environment name, part of every resource name."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region for this environment."
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Availability zone to CIDR mapping for public subnets."
  type        = map(string)
  default = {
    "eu-central-1a" = "10.0.0.0/20"
    "eu-central-1b" = "10.0.16.0/20"
  }
}

variable "private_subnets" {
  description = "Availability zone to CIDR mapping for private subnets."
  type        = map(string)
  default = {
    "eu-central-1a" = "10.0.128.0/20"
    "eu-central-1b" = "10.0.144.0/20"
  }
}

variable "single_nat_gateway" {
  description = "One NAT gateway for the whole VPC instead of one per AZ as a Cost decision"
  type        = bool
  default     = true
}