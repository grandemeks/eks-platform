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

# The bootstrap layer owns this key. Looking it up by alias keeps the two
# stacks decoupled: no remote state reference, no output passed by hand.
data "aws_kms_alias" "platform" {
  name = "alias/${var.project}"
}

module "eks" {
  source = "../../modules/eks"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  kms_key_arn         = data.aws_kms_alias.platform.target_key_arn
  public_access_cidrs = var.cluster_public_access_cidrs

  cluster_admin_principal_arns = var.cluster_admin_principal_arns
}