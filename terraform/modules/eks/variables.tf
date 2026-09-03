variable "name" {
  description = "Cluster name, also used as a prefix for its IAM roles."
  type        = string
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version. Deliberately one release behind the newest:
    new enough to stay well inside standard support, old enough that the
    ecosystem has caught up.
  EOT
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
  description = <<-EOT
    CIDRs allowed to reach the public Kubernetes API endpoint.
    Defaults to the whole internet so CI and a changing home IP both work;
    a production cluster narrows this to known ranges or drops public
    access entirely in favour of a VPN or bastion.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  description = <<-EOT
    Control plane logs shipped to CloudWatch. The audit log is the one that
    matters for a regulated environment: it records every API call made
    against the cluster, by whom, and whether it was allowed.
  EOT
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
  description = <<-EOT
    IAM principals granted cluster-admin. Every administrator is an explicit
    resource here rather than an implicit side effect of who ran apply first.
  EOT
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = <<-EOT
    Instance types for the managed node group. t3.large rather than t3.medium:
    the observability stack alone needs roughly 4.5 GB across Prometheus,
    Grafana, Loki and Argo CD, which leaves a t3.medium pair with no headroom
    and turns any spike into an OOM kill during a live demo. The extra cost is
    about $0.10/hour for the pair.
  EOT
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_capacity_type" {
  description = <<-EOT
    ON_DEMAND or SPOT. Spot would cut compute cost by roughly 70%, but a
    reclaimed node mid-interview is not a trade worth making for a few dollars.
  EOT
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