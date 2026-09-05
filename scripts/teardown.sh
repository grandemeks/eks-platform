#!/usr/bin/env bash
#
# Ordered teardown of the dev environment.
#
# terraform destroy alone is not enough. Three classes of AWS resource exist in
# this environment that Terraform has never seen, because a Kubernetes
# controller created them in response to a Kubernetes object:
#
#   - load balancers, target groups and their ENIs   (load balancer controller)
#   - security groups named k8s-*                    (load balancer controller)
#   - EBS volumes behind PersistentVolumeClaims      (EBS CSI driver)
#
# All three hold references to the VPC or its subnets, so destroy blocks on
# them for twenty minutes and then fails with a dependency violation that names
# an ENI and explains nothing. The volumes are worse than that: they survive
# the destroy entirely and bill quietly at roughly $0.08 per GB-month.
#
# Every wait and every ordering constraint below was added after it broke a
# real teardown.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-eks-platform-dev}"
REGION="${AWS_REGION:-eu-central-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${REPO_ROOT}/terraform/envs/dev"

log()  { printf '\n=== %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*"; }

# Poll until a command returns empty output, or give up. Used instead of fixed
# sleeps: AWS deletions are asynchronous and their duration varies by an order
# of magnitude between runs.
wait_until_empty() {
  local what="$1" attempts="$2"; shift 2
  local i
  for i in $(seq 1 "$attempts"); do
    if [ -z "$("$@" 2>/dev/null || true)" ]; then
      printf '    %s gone\n' "$what"
      return 0
    fi
    printf '.'
    sleep 10
  done
  echo
  warn "$what still present after $((attempts * 10))s, continuing anyway"
  return 0
}

list_albs() {
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query 'LoadBalancers[].LoadBalancerName' --output text
}

# ---------------------------------------------------------------------------
# 1. Drop the Helm releases from state before anything else.
#
# The helm provider authenticates using the cluster's endpoint and an exec
# credential. Once the cluster is gone it cannot authenticate, but Terraform
# still tries to run helm uninstall and hangs until its own timeout — there is
# no dependency edge telling it that Argo CD lives inside the thing being
# deleted. Removing the releases from state is accurate rather than evasive:
# deleting the cluster deletes everything in it.
# ---------------------------------------------------------------------------
log "Removing Helm releases from Terraform state"
(
  cd "$ENV_DIR"
  for res in helm_release.root_app helm_release.argocd; do
    terraform state rm "$res" >/dev/null 2>&1 \
      && printf '    removed %s\n' "$res" \
      || printf '    %s not in state\n' "$res"
  done
)

# ---------------------------------------------------------------------------
# 2. Kubernetes phase. Skipped entirely if the cluster is already gone.
# ---------------------------------------------------------------------------
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  export KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kubeconfig}"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null

  # Argo CD has selfHeal enabled and will faithfully recreate everything
  # deleted underneath it. Disabling automated sync first is what stops the two
  # from fighting.
  log "Disabling Argo CD automated sync"
  for app in $(kubectl -n argocd get applications -o name 2>/dev/null || true); do
    kubectl -n argocd patch "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
  done

  log "Deleting Ingresses"
  kubectl delete ingress --all-namespaces --all --wait=true --timeout=3m || true

  log "Deleting LoadBalancer Services"
  kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
  | while read -r ns name; do
      [ -n "${ns:-}" ] && kubectl -n "$ns" delete svc "$name" --wait=true --timeout=3m || true
    done

  # The controller reconciles asynchronously. kubectl returning is not the same
  # as the load balancer being gone, and moving on early is what left an ALB
  # holding ENIs through a thirteen-minute destroy.
  log "Waiting for load balancers to be removed"
  wait_until_empty "load balancers" 30 list_albs

  # Workloads before their volumes. A PVC carries a pvc-protection finalizer
  # that is only released once no pod mounts it, so deleting claims while
  # Prometheus and Grafana are still running blocks in Terminating forever.
  log "Deleting workloads that hold volumes"
  for ns in $(kubectl get pvc --all-namespaces \
                -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u); do
    [ -z "$ns" ] && continue
    kubectl -n "$ns" delete statefulset --all --wait=false >/dev/null 2>&1 || true
    kubectl -n "$ns" delete deployment  --all --wait=false >/dev/null 2>&1 || true
  done

  log "Waiting for pods to release their volumes"
  kubectl wait --for=delete pod --all --all-namespaces --timeout=3m >/dev/null 2>&1 || true

  # Deleting the claim is what makes the CSI driver delete the underlying EBS
  # volume. Terraform cannot do this — the volume is not in its state.
  log "Deleting PersistentVolumeClaims"
  kubectl delete pvc --all-namespaces --all --wait=true --timeout=3m || true
else
  log "Cluster not found, skipping Kubernetes phase"
fi

# ---------------------------------------------------------------------------
# 3. Security groups the controller created.
#
# A VPC cannot be deleted while it contains any non-default security group.
# These are named k8s-* and belong to no Terraform resource, so they survive
# every phase above and block the VPC at the very last step.
# ---------------------------------------------------------------------------
log "Deleting leftover k8s-* security groups"
for sg in $(aws ec2 describe-security-groups --region "$REGION" \
              --filters "Name=group-name,Values=k8s-*" \
              --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true); do
  # Order matters: groups reference each other, so a first pass can fail with
  # DependencyViolation and succeed on the second once the referrer is gone.
  aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 \
    && printf '    deleted %s\n' "$sg" || true
done
for sg in $(aws ec2 describe-security-groups --region "$REGION" \
              --filters "Name=group-name,Values=k8s-*" \
              --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true); do
  aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 \
    && printf '    deleted %s on retry\n' "$sg" \
    || warn "could not delete $sg, terraform may block on the VPC"
done

# ---------------------------------------------------------------------------
# 4. Terraform.
# ---------------------------------------------------------------------------
log "terraform destroy"
cd "$ENV_DIR"
terraform destroy "$@"

# ---------------------------------------------------------------------------
# 5. Orphaned volumes.
#
# If the Kubernetes phase was skipped or interrupted, the CSI driver never
# deleted its volumes and nothing else will. They are identifiable by the tag
# the driver writes, so this is safe to automate rather than leaving as a
# manual check nobody performs.
# ---------------------------------------------------------------------------
log "Deleting orphaned CSI volumes"
for vol in $(aws ec2 describe-volumes --region "$REGION" \
               --filters Name=status,Values=available \
                         "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
               --query 'Volumes[].VolumeId' --output text 2>/dev/null || true); do
  aws ec2 delete-volume --region "$REGION" --volume-id "$vol" \
    && printf '    deleted %s\n' "$vol"
done

# ---------------------------------------------------------------------------
# 6. Verify. An empty result for every line means nothing is still billing.
# ---------------------------------------------------------------------------
log "Verification — every line below must be empty"
printf '%-18s %s\n' "clusters:"       "$(aws eks list-clusters --region "$REGION" --query 'clusters' --output text)"
printf '%-18s %s\n' "vpcs:"           "$(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[?!IsDefault].VpcId' --output text)"
printf '%-18s %s\n' "nat gateways:"   "$(aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text)"
printf '%-18s %s\n' "elastic ips:"    "$(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].PublicIp' --output text)"
printf '%-18s %s\n' "load balancers:" "$(list_albs)"
printf '%-18s %s\n' "volumes:"        "$(aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text)"
printf '%-18s %s\n' "rds instances:"  "$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].DBInstanceIdentifier' --output text)"
printf '%-18s %s\n' "security groups:" "$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=k8s-*" --query 'SecurityGroups[].GroupId' --output text)"

log "Bootstrap layer is intentionally left running: state bucket, KMS key, DNS zone, ECR, certificate, CI roles."