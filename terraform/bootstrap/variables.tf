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

variable "dns_zone_name" {
  description = "Subdomain hosted in this account"
  type        = string
  default     = "incode-demo.grandemeks.tech"
}

variable "github_owner" {
  description = "GitHub user that owns repo allowed to assume the CI roles."
  type        = string
  default     = "grandemeks"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI roles."
  type        = string
  default     = "eks-platform"
}