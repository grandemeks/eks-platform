# EKS ships only a gp2 StorageClass, and it is not even marked default on newer
# clusters. gp3 is cheaper per GB and, more importantly, its baseline
# throughput and IOPS are independent of volume size — a 5 GB gp2 volume gets
# 100 IOPS, which is not enough for Prometheus.
#
# Created through the Kubernetes API rather than as an EKS add-on because no
# add-on exists for storage classes; the EBS CSI driver provides the
# provisioner, but the class itself is an ordinary cluster object.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }

  # Terraform infers dependencies from references, and this resource
  # references only the KMS key — nothing that tells it a cluster must exist
  # and be reachable first. Without this the provider tries to authenticate
  # against an API server that is up but has not yet granted the caller access,
  # and returns a bare "Unauthorized" that names nothing.
  #
  # The access policy association is the real prerequisite: the CI role
  # authenticates through it. The node group is listed too, because a cluster
  # with no schedulable nodes is not a useful target for a storage class.
  depends_on = [
    aws_eks_access_policy_association.admin,
    aws_eks_node_group.this,
  ]
  }

  storage_provisioner = "ebs.csi.aws.com"

  # WaitForFirstConsumer, not Immediate. An EBS volume exists in one
  # availability zone and can only be attached by a node in that zone. Binding
  # immediately would create the volume before the scheduler has picked a node,
  # and roughly half the time the pod lands in the other AZ and can never
  # attach it.
  volume_binding_mode = "WaitForFirstConsumer"

  # Volumes are deleted with their claim. Correct for an environment that is
  # torn down daily; production would use Retain for anything holding data
  # worth recovering.
  reclaim_policy = "Delete"

  # Lets a PVC be resized in place instead of requiring a migration.
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = var.kms_key_arn
  }
}