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
  description = "IAM principals granted cluster-admin on the cluster."
  type        = list(string)
  default     = []
}

variable "argocd_chart_version" {
  description = <<-EOT
    Argo CD Helm chart version. Pinned rather than floating: an unpinned chart
    means a rebuild months from now installs a different Argo CD than the one
    this repository was tested against.

    Verify what is current with:
      helm repo add argo https://argoproj.github.io/argo-helm
      helm search repo argo/argo-cd --versions | head
  EOT
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