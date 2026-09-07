variable "name" {
  description = "Cluster name, also used as a prefix for its IAM roles."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. Kept one release behind the newest so the surrounding ecosystem has caught up, while staying inside standard support."
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC the cluster is created in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets for control plane ENIs and worker nodes."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "CMK used for envelope encryption of Kubernetes secrets in etcd."
  type        = string
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Open by default so CI and a changing home IP both work; a production cluster should narrow this."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  description = "Control plane log types shipped to CloudWatch. The audit log records every API call against the cluster, by whom, and whether it was allowed."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags for resources in this module."
  type        = map(string)
  default     = {}
}

variable "cluster_admin_principal_arns" {
  description = "IAM principals granted cluster-admin, each created as an explicit access entry."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. The observability stack and Argo CD need roughly 4.5 GB, which leaves a pair of t3.medium nodes without headroom."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot is roughly 70 percent cheaper but nodes can be reclaimed at any time."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_disk_size" {
  description = "Root volume size in GB per node."
  type        = number
  default     = 30
}