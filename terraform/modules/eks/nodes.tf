data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

# Two policies only. Notably absent is AmazonEKS_CNI_Policy: the VPC CNI runs
# with its own IRSA role instead, so the permission to manipulate ENIs and IP
# addresses belongs to that one add-on rather than to every process on
# every node.
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# PullOnly rather than ReadOnly: it is the narrower of the two and is what AWS
# now documents for node roles. ReadOnly additionally allows listing images,
# reading lifecycle policies and reading scan findings, none of which a kubelet
# needs in order to pull an image.
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type
  disk_size      = var.node_disk_size

  # AL2023 is the current default. Amazon Linux 2 is end of life.
  ami_type = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    # With two nodes, replacing one at a time keeps half the capacity online
    # through a version upgrade.
    max_unavailable = 1
  }

  # Networking must be functional before nodes join, or the kubelet registers
  # and then sits unready because no pod can get an IP address.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_ecr,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  lifecycle {
    # A cluster autoscaler or Karpenter would own desired_size at runtime.
    # Not enabled here, but this is where that boundary is drawn.
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = var.tags
}