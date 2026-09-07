# EKS ships only gp2, unmarked as default on newer clusters. gp3 is cheaper per
# GB and its baseline IOPS is independent of size: a 5 GB gp2 volume gets 100
# IOPS, not enough for Prometheus. No EKS add-on exists for storage classes.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"

  # An EBS volume is zonal. Binding before the scheduler picks a node strands
  # the pod in the wrong AZ about half the time with two AZs.
  volume_binding_mode = "WaitForFirstConsumer"

  # Torn down daily. Production wants Retain for anything worth recovering.
  reclaim_policy = "Delete"

  # Resize a PVC in place instead of migrating it.
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = var.kms_key_arn
  }

  # Only the KMS key is referenced, nothing implying a reachable cluster.
  # Without this the provider hits an API server that has not yet granted the
  # caller access and returns a bare Unauthorized.
  depends_on = [
    aws_eks_access_policy_association.admin,
    aws_eks_node_group.this,
  ]
}