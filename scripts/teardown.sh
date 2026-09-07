#!/usr/bin/env bash
#
# Ordered teardown of the dev environment. The order is load-bearing.
#
# A bare terraform destroy leaves orphans: deleting the cluster kills the CSI
# driver and load balancer controller mid-reconcile, so PVCs become stranded EBS
# volumes and Ingresses become stranded ALBs plus security groups, and those
# security groups then block the VPC delete. So: drain via the Kubernetes API
# while it still answers, destroy in stages, sweep by tag, verify against AWS.

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-eks-platform-dev}"
REGION="${AWS_REGION:-eu-central-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${REPO_ROOT}/terraform/envs/dev"

# Passed through to terraform destroy, so CI can supply -auto-approve.
TF_ARGS=("$@")

log()  { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*"; }

# --- Helpers ---------------------------------------------------------------

# Poll rather than sleep: AWS delete latency varies by an order of magnitude,
# so any fixed sleep is either unsafe or absurdly long. Never fails the run.
wait_until_empty() {
  local what="$1" attempts="$2"; shift 2
  local i out
  for i in $(seq 1 "$attempts"); do
    out="$("$@" 2>/dev/null)"
    if [ -z "$out" ]; then
      info "$what: gone"
      return 0
    fi
    printf '.'
    sleep 10
  done
  echo
  warn "$what: still present after $((attempts * 10))s, continuing"
  return 0
}

# Tag lookup is the only handle on these: not in Terraform state, and the names
# are hashed.
lbc_load_balancers() {
  aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null
}

lbc_target_groups() {
  aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
    --resource-type-filters elasticloadbalancing:targetgroup \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null
}

lbc_security_groups() {
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null
}

# Service-type LoadBalancer groups carry a different tag than the controller's
# Ingress groups, so both queries are needed.
ccm_security_groups() {
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null
}

csi_volumes() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters Name=status,Values=available \
              "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null
}

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Phase 1: Kubernetes drain. All of it must run while the API server still
# answers; after the cluster is gone the controllers cannot clean up after
# themselves.
# ---------------------------------------------------------------------------
drain_kubernetes() {
  if ! cluster_exists; then
    log "Kubernetes drain skipped, cluster not found"
    return 0
  fi

  export KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kubeconfig}"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1

  if ! kubectl get --raw /readyz >/dev/null 2>&1; then
    warn "cluster API not reachable, skipping drain; expect orphans for the sweep to catch"
    return 0
  fi

  # First: selfHeal is on, so Argo recreates anything deleted below this point.
  log "Disabling Argo CD automated sync"
  for app in $(kubectl -n argocd get applications -o name 2>/dev/null); do
    kubectl -n argocd patch "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1
  done

  # Strip Argo finalizers before the controller goes: with nothing left to run
  # them the Applications stick in Terminating and block the owning helm_release.
  log "Removing finalizers from Argo CD Applications"
  for app in $(kubectl -n argocd get applications -o name 2>/dev/null); do
    kubectl -n argocd patch "$app" --type merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
    info "finalizer cleared: ${app#*/}"
  done
  kubectl -n argocd delete applications --all --wait=false >/dev/null 2>&1

  # All in one call: these share an ALB group, and deleting them one at a time
  # leaves the group non-empty, so the controller recreates the ALB and a new
  # security group with it, after the sweep has run.
  log "Deleting Ingresses"
  kubectl delete ingress --all-namespaces --all --wait=false >/dev/null 2>&1
  kubectl delete ingress --all-namespaces --all --wait=true --timeout=2m 2>/dev/null

  log "Deleting LoadBalancer Services"
  kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while read -r ns name; do
      [ -n "${ns:-}" ] && kubectl -n "$ns" delete svc "$name" --wait=true --timeout=2m 2>/dev/null
    done

  # kubectl returning does not mean the ALB is gone; moving on early leaves it
  # holding ENIs and the destroy fails.
  log "Waiting for load balancers to disappear"
  wait_until_empty "load balancers" 30 lbc_load_balancers

  # Workloads before their claims: the pvc-protection finalizer only clears once
  # no pod mounts the volume.
  log "Deleting workloads that hold volumes"
  local namespaces
  namespaces="$(kubectl get pvc --all-namespaces \
                  -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u)"
  for ns in $namespaces; do
    [ -z "$ns" ] && continue
    kubectl -n "$ns" delete statefulset,deployment --all --wait=false >/dev/null 2>&1
    info "workloads deleted in namespace: $ns"
  done

  if [ -n "$namespaces" ]; then
    log "Waiting for pods to release their volumes"
    for ns in $namespaces; do
      [ -z "$ns" ] && continue
      kubectl -n "$ns" wait --for=delete pod --all --timeout=2m >/dev/null 2>&1
    done
  fi

  # Deleting the claim is the only way to get the EBS volume deleted; it is not
  # in Terraform state. --wait=false then poll: a blocking delete on a claim
  # whose finalizer has not cleared hangs the full timeout and reports failure.
  log "Deleting PersistentVolumeClaims"
  kubectl delete pvc --all-namespaces --all --wait=false >/dev/null 2>&1
  wait_until_empty "persistent volume claims" 18 \
    kubectl get pvc --all-namespaces --no-headers -o name

  log "Waiting for the CSI driver to delete the underlying volumes"
  wait_until_empty "detached CSI volumes" 18 csi_volumes
}

# ---------------------------------------------------------------------------
# Phase 2: Terraform, in two -target passes. The load balancer controller runs
# inside the cluster, so the sweep is only meaningful once the cluster is gone.
# One pass races the VPC delete against the sweep and fails with an ENI
# DependencyViolation. The graph cannot express this: the dependency lives
# inside a resource Terraform manages.
# ---------------------------------------------------------------------------
terraform_destroy() {
  cd "$ENV_DIR" || exit 1

  # A CI runner has no .terraform directory.
  log "terraform init"
  terraform init -input=false >/dev/null || { warn "init failed"; exit 1; }

  # Must precede the cluster destroy: nothing tells Terraform that these releases
  # live inside the cluster, so it attempts helm uninstall against a dead
  # endpoint and hangs until its own timeout. Deleting the cluster removes them.
  log "Removing Helm releases from state"
  for res in helm_release.root_app helm_release.argocd; do
    if terraform state rm "$res" >/dev/null 2>&1; then
      info "removed: $res"
    else
      info "not in state: $res"
    fi
  done

  log "Destroying the cluster and database"
  terraform destroy "${TF_ARGS[@]}" \
    -target=module.eks -target=module.database -lock-timeout=10m

  sweep_orphans

  log "Destroying the remaining infrastructure"
  if ! terraform destroy "${TF_ARGS[@]}" -lock-timeout=10m; then
    # One retry after a second sweep: a resource that reports a dependency now
    # is often deletable a minute later.
    warn "destroy failed, sweeping again and retrying once"
    sweep_orphans
    terraform destroy "${TF_ARGS[@]}" -lock-timeout=10m || {
      warn "destroy failed twice; inspect manually before assuming nothing is billing"
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# Phase 3: orphan sweep. Only valid after the cluster is destroyed, otherwise
# the controller recreates what this deletes.
# ---------------------------------------------------------------------------
sweep_orphans() {
  log "Sweeping resources the controllers left behind"

  for arn in $(lbc_load_balancers); do
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" >/dev/null 2>&1 \
      && info "deleted load balancer: ${arn##*/}"
  done

  # Wait here before touching security groups: ALBs release their ENIs
  # asynchronously, and those ENIs hold both the groups and the subnets.
  if [ -n "$(lbc_load_balancers)" ]; then
    wait_until_empty "load balancers" 18 lbc_load_balancers
    sleep 20
  fi

  for arn in $(lbc_target_groups); do
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" >/dev/null 2>&1 \
      && info "deleted target group: ${arn##*/}"
  done

  # Two passes: the frontend group references the shared backend group, so the
  # backend delete only succeeds after the referring group is gone.
  for pass in 1 2; do
    for sg in $(lbc_security_groups) $(ccm_security_groups); do
      aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 \
        && info "deleted security group: $sg (pass $pass)"
    done
  done

  for vol in $(csi_volumes); do
    aws ec2 delete-volume --region "$REGION" --volume-id "$vol" >/dev/null 2>&1 \
      && info "deleted volume: $vol"
  done

  local remaining
  remaining="$(lbc_security_groups) $(ccm_security_groups)"
  if [ -n "${remaining// /}" ]; then
    warn "security groups still present: $remaining"
    warn "these will block VPC deletion; they usually clear once load balancer ENIs are released"
  fi
}

# ---------------------------------------------------------------------------
# Phase 4: verify against the AWS API, not the destroy output. Terraform
# succeeding only means it deleted what it knew about.
# ---------------------------------------------------------------------------
verify() {
  log "Verification: every line must be empty"

  local failed=0
  check() {
    local label="$1"; shift
    local out; out="$("$@" 2>/dev/null | tr '\t' ' ')"
    printf '    %-22s %s\n' "$label" "${out:-none}"
    [ -n "$out" ] && failed=1
    return 0
  }

  check "clusters:"        aws eks list-clusters --region "$REGION" --query 'clusters' --output text
  check "vpcs:"            aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[?!IsDefault].VpcId' --output text
  check "nat gateways:"    aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
  check "elastic ips:"     aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].PublicIp' --output text
  check "load balancers:"  aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
  check "target groups:"   aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[].TargetGroupName' --output text
  check "volumes:"         aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
  check "rds instances:"   aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].DBInstanceIdentifier' --output text
  check "k8s sec groups:"  aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=k8s-*" --query 'SecurityGroups[].GroupId' --output text

  echo
  if [ "$failed" -eq 0 ]; then
    log "Nothing is billing."
  else
    warn "Something above is still present. Investigate before walking away."
  fi

  info "The bootstrap layer stays up by design: state bucket, KMS key, DNS zone,"
  info "ECR repository, certificate and CI roles: roughly \$1.50/month."

  return "$failed"
}

# ---------------------------------------------------------------------------
main() {
  log "Tearing down $CLUSTER_NAME in $REGION"
  drain_kubernetes
  terraform_destroy || true
  verify
}

main