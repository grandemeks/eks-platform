variable "project" {
  description = "Short project name used as a prefix for every resource name."
  type        = string
  default     = "eks-platform"
}

variable "region" {
  description = "AWS region for the shared/persistent layer."
  type        = string
  default     = "eu-central-1"
}