locals {
  name = "${var.project}-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  single_nat_gateway = var.single_nat_gateway
}

# Alias lookup rather than remote state: no read dependency on bootstrap.
data "aws_kms_alias" "platform" {
  name = "alias/${var.project}"
}
# An assumed role presents a session ARN, which an EKS access entry rejects.
# aws_iam_session_context resolves it back to the role ARN that issued it.
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

module "eks" {
  source = "../../modules/eks"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  kms_key_arn         = data.aws_kms_alias.platform.target_key_arn
  public_access_cidrs = var.cluster_public_access_cidrs

  cluster_admin_principal_arns = distinct(concat(
    var.cluster_admin_principal_arns,
    [data.aws_iam_session_context.current.issuer_arn],
  ))
}

module "database" {
  source = "../../modules/database"

  name               = local.name
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  # Pods share the node's ENI under the VPC CNI, so the cluster security group
  # is what grants a pod access to the database.
  allowed_security_group_ids = {
    eks_cluster = module.eks.cluster_security_group_id
  }

  kms_key_arn = data.aws_kms_alias.platform.target_key_arn
}