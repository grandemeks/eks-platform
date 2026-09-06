#!/usr/bin/env bash
#
# Ordered teardown of the dev environment.
#
# terraform destroy alone does not work here, and that is not a defect in this
# repository. Deleting an EKS cluster tears down the control plane but does not
# drain what is running on it, so the CSI driver and the load balancer
# controller lose their API server mid-reconcile. PersistentVolumeClaims become
# orphaned EBS volumes, Ingresses become orphaned load balancers and security
# groups, and those security groups then block the VPC from being deleted at
# all. AWS ships a standalone cleanup script alongside its own EKS reference
# architecture for exactly this reason.
#
# The shape of the solution is therefore: drain through the Kubernetes API
# while it is still alive, destroy in stages so the controller is provably gone
# before its leftovers are swept, then verify against the AWS API rather than
# trusting the destroy output.
#
# Every wait, every ordering constraint and every sweep below was added after
# it broke a real teardown.

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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Poll until a command produces no output. Used instead of fixed sleeps because
# AWS deletions are asynchronous and vary by an order of magnitude between runs
# — a sleep long enough to be safe is far longer than the usual case.
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

# Resources the load balancer controller creates carry this tag. It is the only
# reliable way to find them: they are not in Terraform state, and their names
# contain a hash rather than anything predictable.
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

# Security groups the in-tree cloud provider creates for type=LoadBalancer
# Services carry a different tag than the ones the load balancer controller
# creates for Ingresses.
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
# Phase 1 — Kubernetes drain
#
# Everything here must happen while the API server is still answering. Once the
# cluster is gone the controllers are gone with it, and their AWS resources
# become orphans nothing will ever clean up.
# ---------------------------------------------------------------------------
drain_kubernetes() {
  if ! cluster_exists; then
    log "Kubernetes drain — skipped, cluster not found"
    return 0
  fi

  export KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/.kubeconfig}"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1

  if ! kubectl get --raw /readyz >/dev/null 2>&1; then
    warn "cluster API not reachable, skipping drain — expect orphans for the sweep to catch"
    return 0
  fi

  # Argo CD has selfHeal enabled and will faithfully recreate anything deleted
  # underneath it. Disabling automated sync first is what stops the two systems
  # from fighting each other for the length of the teardown.
  log "Disabling Argo CD automated sync"
  for app in $(kubectl -n argocd get applications -o name 2>/dev/null); do
    kubectl -n argocd patch "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1
  done

  # Argo Applications carry resources-finalizer.argocd.argoproj.io, which exists
  # so that deleting an Application also deletes what it deployed. During
  # teardown that guarantee inverts: if the controller is removed before the
  # Application, nothing is left to run the finalizer and the object stays in
  # Terminating forever — taking any helm_release that owns it down with it.
  log "Removing finalizers from Argo CD Applications"
  for app in $(kubectl -n argocd get applications -o name 2>/dev/null); do
    kubectl -n argocd patch "$app" --type merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
    info "finalizer cleared: ${app#*/}"
  done
  kubectl -n argocd delete applications --all --wait=false >/dev/null 2>&1

  # Deleted in one call rather than one at a time. With a shared ALB group,
  # removing Ingresses individually leaves the group non-empty between
  # deletions, and the controller reconciles the remaining members by
  # recreating the load balancer — and a fresh security group with it — after
  # the sweep has already run.
  log "Deleting Ingresses"
  kubectl delete ingress --all-namespaces --all --wait=false >/dev/null 2>&1
  kubectl delete ingress --all-namespaces --all --wait=true --timeout=2m 2>/dev/null

  log "Deleting LoadBalancer Services"
  kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while read -r ns name; do
      [ -n "${ns:-}" ] && kubectl -n "$ns" delete svc "$name" --wait=true --timeout=2m 2>/dev/null
    done

  # kubectl returning is not the same as the load balancer being gone. Moving
  # on early is what left an ALB holding ENIs through a thirteen-minute destroy
  # that then failed.
  log "Waiting for load balancers to disappear"
  wait_until_empty "load balancers" 30 lbc_load_balancers

  # Workloads before their volumes. A PVC carries a pvc-protection finalizer
  # that is only released once no pod mounts it, so deleting claims while
  # Prometheus and Grafana are still running blocks until the timeout and
  # achieves nothing.
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

  # Deleting the claim is what makes the CSI driver delete the underlying EBS
  # volume. Terraform cannot do this: the volume is not in its state, because a
  # controller created it in response to a Kubernetes object.
  #
  # --wait=false then poll, rather than --wait=true. A blocking delete against
  # a claim whose finalizer has not cleared hangs for the full timeout and then
  # reports failure, even though the deletion is progressing normally.
  log "Deleting PersistentVolumeClaims"
  kubectl delete pvc --all-namespaces --all --wait=false >/dev/null 2>&1
  wait_until_empty "persistent volume claims" 18 \
    kubectl get pvc --all-namespaces --no-headers -o name

  log "Waiting for the CSI driver to delete the underlying volumes"
  wait_until_empty "detached CSI volumes" 18 csi_volumes
}

# ---------------------------------------------------------------------------
# Phase 2 — Terraform
#
# Destroyed in two passes on purpose.
#
# The load balancer controller runs inside the cluster, so its leftovers cannot
# be swept while it might still recreate them. Destroying the cluster first
# guarantees it is gone; only then is the sweep meaningful. Attempting the
# whole stack in one pass means the VPC deletion races the sweep and fails with
# a DependencyViolation naming an ENI, which explains nothing.
#
# -target is normally a smell. Here it is the point: teardown genuinely has an
# ordering requirement that the dependency graph cannot express, because the
# dependency runs inside a resource Terraform manages rather than beside it.
# ---------------------------------------------------------------------------
terraform_destroy() {
  cd "$ENV_DIR" || exit 1

  # A CI runner has no .terraform directory. Cheap locally, essential there.
  log "terraform init"
  terraform init -input=false >/dev/null || { warn "init failed"; exit 1; }

  # The helm provider authenticates using the cluster endpoint and an exec
  # credential. Once the cluster is gone it cannot authenticate, but Terraform
  # still attempts helm uninstall and hangs until its own timeout — there is no
  # dependency edge telling it that Argo CD lives inside the thing being
  # deleted. Removing the releases from state is accurate rather than evasive:
  # deleting a cluster deletes everything in it.
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
    # One retry after a second sweep. Deletion ordering in AWS is partly
    # eventual: a resource that reports a dependency now can become deletable a
    # minute later once something upstream finishes releasing it.
    warn "destroy failed, sweeping again and retrying once"
    sweep_orphans
    terraform destroy "${TF_ARGS[@]}" -lock-timeout=10m || {
      warn "destroy failed twice — inspect manually before assuming nothing is billing"
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# Phase 3 — Orphan sweep
#
# Runs after the cluster is destroyed and the controller is provably gone.
# Everything here is identified by tag, because none of it is in Terraform
# state and none of it has a predictable name.
# ---------------------------------------------------------------------------
sweep_orphans() {
  log "Sweeping resources the controllers left behind"

  for arn in $(lbc_load_balancers); do
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" >/dev/null 2>&1 \
      && info "deleted load balancer: ${arn##*/}"
  done

  # Load balancers release their ENIs asynchronously, and those ENIs are what
  # actually hold the subnets. Deleting security groups before the ENIs are
  # released fails; deleting the VPC before them fails too.
  if [ -n "$(lbc_load_balancers)" ]; then
    wait_until_empty "load balancers" 18 lbc_load_balancers
    sleep 20
  fi

  for arn in $(lbc_target_groups); do
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" >/dev/null 2>&1 \
      && info "deleted target group: ${arn##*/}"
  done

  # Two passes. The frontend security group the controller creates for a load
  # balancer references the shared backend group, so the first attempt on the
  # backend group fails with DependencyViolation and succeeds once the
  # referring group is gone.
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
# Phase 4 — Verify
#
# Against the AWS API, not against the destroy output. Terraform reporting
# success only means it deleted what it knew about.
# ---------------------------------------------------------------------------
verify() {
  log "Verification — every line must be empty"

  local failed=0
  check() {
    local label="$1"; shift
    local out; out="$("$@" 2>/dev/null | tr '\t' ' ')"
    printf '    %-22s %s\n' "$label" "${out:-—}"
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
  info "ECR repository, certificate and CI roles — roughly \$1.50/month."

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