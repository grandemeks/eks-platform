#!/usr/bin/env bash
#
# Ordered teardown of the dev environment.
#
# terraform destroy alone is not enough once the cluster is running. The AWS
# Load Balancer Controller creates load balancers, target groups, security
# groups and ENIs that Terraform has never seen, because they were created by a
# controller reacting to a Kubernetes object rather than by Terraform. Those
# resources hold references to the subnets Terraform is trying to delete, so
# destroy hangs for around twenty minutes and then fails with a dependency
# violation that names an ENI and explains nothing.
#
# The fix is ordering: delete the Kubernetes objects that own AWS resources,
# wait for the controllers to clean up after themselves, and only then destroy
# the infrastructure underneath.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-eks-platform-dev}"
REGION="${AWS_REGION:-eu-central-1}"
ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform/envs/dev" && pwd)"

log() { printf '\n=== %s\n' "$*"; }

# The cluster may already be gone, in which case the Kubernetes phase is a
# no-op and we go straight to Terraform.
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null

  # Argo CD would recreate anything deleted underneath it, because selfHeal is
  # on. Disabling automated sync first is what stops the two from fighting.
  log "Disabling Argo CD automated sync"
  for app in $(kubectl -n argocd get applications -o name 2>/dev/null || true); do
    kubectl -n argocd patch "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
  done

  log "Deleting Ingresses so the controller removes its load balancers"
  kubectl delete ingress --all-namespaces --all --wait=true --timeout=5m || true

  log "Deleting LoadBalancer Services"
  kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
  | while read -r ns name; do
      [ -n "${ns:-}" ] && kubectl -n "$ns" delete svc "$name" --wait=true --timeout=5m || true
    done

  # PersistentVolumeClaims become EBS volumes. Deleting the claim lets the CSI
  # driver delete the volume; skipping this leaves orphaned volumes billing
  # quietly at $0.08/GB-month.
  log "Deleting PersistentVolumeClaims"
  kubectl delete pvc --all-namespaces --all --wait=true --timeout=5m || true

  # Deletion is asynchronous. Without this the controller is still working when
  # Terraform starts pulling the subnets out from under it.
  log "Waiting for load balancers to disappear"
  for _ in $(seq 1 30); do
    remaining=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancers[?VpcId!=null])" --output text 2>/dev/null || echo 0)
    [ "$remaining" = "0" ] && break
    printf '.'
    sleep 10
  done
  echo
else
  log "Cluster not found, skipping Kubernetes phase"
fi

log "terraform destroy"
cd "$ENV_DIR"
terraform destroy "$@"

log "Verifying nothing is left billing"
aws ec2 describe-nat-gateways --region "$REGION" \
  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].PublicIp' --output text
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
aws ec2 describe-volumes --region "$REGION" \
  --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].DBInstanceIdentifier' --output text

log "Done. Empty output above means nothing is left."