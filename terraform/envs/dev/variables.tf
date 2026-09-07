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
  description = "Use one NAT gateway for the whole VPC instead of one per AZ, to keep cost down."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the cluster."
  type        = string
  default     = "1.35"
}

variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_principal_arns" {
  description = "Extra IAM principals granted cluster-admin, beyond whoever runs the apply. An IAM ARN is not a secret, so this has a default in code rather than living only in gitignored tfvars, where a CI apply would see an empty list and revoke the access entry."
  type        = list(string)
  default     = ["arn:aws:iam::385291933614:user/milos-admin"]
}

variable "argocd_chart_version" {
  description = "Argo CD Helm chart version, pinned so a later rebuild installs the same release. List available versions with: helm search repo argo/argo-cd --versions"
  type        = string
  default     = "10.6.4"
}

variable "gitops_repo_url" {
  description = "Repository Argo CD reconciles the cluster against."
  type        = string
  default     = "https://github.com/grandemeks/eks-platform.git"
}

variable "gitops_target_revision" {
  description = "Branch or tag Argo tracks."
  type        = string
  default     = "main"
}

variable "dns_zone_name" {
  description = "Delegated subdomain hosted in this account, owned by the bootstrap layer."
  type        = string
  default     = "incode-demo.grandemeks.tech"
}

variable "app_hostname" {
  description = "Hostname the demo application is served on."
  type        = string
  default     = "incode-demo.grandemeks.tech"
}