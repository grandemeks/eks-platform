#!/usr/bin/env bash
#
# Copy Terraform outputs into the Argo CD values files.
#
# Seven values in this repository are produced by Terraform and consumed by
# Kubernetes, and most of them change every time the environment is recreated:
#
#   database endpoint      new RDS instance
#   database secret ARN    RDS generates a fresh Secrets Manager secret
#   VPC id                 new VPC
#   IRSA role ARNs         new cluster means a new OIDC provider
#   ACM certificate ARN    stable; it lives in the bootstrap layer
#
# Terraform cannot write them itself: Argo CD reads desired state from Git, not
# from Terraform state, and Terraform has no business committing to the
# repository. So a manual copying step exists — and a manual copying step
# performed after every destroy/apply cycle is a defect waiting to happen.
# Three separate failures during development traced back to a stale ARN here.
#
# Run after terraform apply, review the diff, commit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${REPO_ROOT}/terraform/envs/dev"
BOOTSTRAP_DIR="${REPO_ROOT}/terraform/bootstrap"

DEMO_VALUES="${REPO_ROOT}/argocd/configs/demo-app/values-dev.yaml"
LBC_VALUES="${REPO_ROOT}/argocd/configs/infrastructure/aws-load-balancer-controller-values.yaml"
DNS_VALUES="${REPO_ROOT}/argocd/configs/infrastructure/external-dns-values.yaml"
GRAFANA_VALUES="${REPO_ROOT}/argocd/configs/infrastructure/kube-prometheus-stack-values.yaml"

log() { printf '\n=== %s\n' "$*"; }

tf_output() { terraform -chdir="$1" output -raw "$2" 2>/dev/null || true; }

log "Reading Terraform outputs"

DB_ENDPOINT="$(tf_output "$ENV_DIR" database_endpoint)"
DB_SECRET_ARN="$(tf_output "$ENV_DIR" database_secret_arn)"
VPC_ID="$(tf_output "$ENV_DIR" vpc_id)"
ROLE_SECRETS="$(tf_output "$ENV_DIR" irsa_demo_app_secrets_role_arn)"
ROLE_LBC="$(tf_output "$ENV_DIR" irsa_aws_load_balancer_controller_role_arn)"
ROLE_DNS="$(tf_output "$ENV_DIR" irsa_external_dns_role_arn)"
CERT_ARN="$(tf_output "$BOOTSTRAP_DIR" acm_certificate_arn)"

# The endpoint output is host:port; the chart keeps them as separate values so
# a port change is not a string-parsing exercise.
DB_HOST="${DB_ENDPOINT%%:*}"

# Fail loudly rather than writing an empty string into a values file, which
# would produce a Helm render error far from its cause.
for pair in "database_endpoint=$DB_ENDPOINT" \
            "database_secret_arn=$DB_SECRET_ARN" \
            "vpc_id=$VPC_ID" \
            "irsa_demo_app_secrets=$ROLE_SECRETS" \
            "irsa_lbc=$ROLE_LBC" \
            "irsa_external_dns=$ROLE_DNS" \
            "acm_certificate_arn=$CERT_ARN"; do
  name="${pair%%=*}"; value="${pair#*=}"
  if [ -z "$value" ]; then
    printf 'ERROR: output %s is empty. Has terraform apply completed?\n' "$name" >&2
    exit 1
  fi
  printf '    %-26s %s\n' "$name" "$value"
done

# Rewrite one key in place, anchored to its parent section.
#
# A targeted line rewrite rather than a round-trip through yq: every one of
# these files carries comments explaining why a value is what it is, and a
# YAML round-trip discards them silently. The comments are the documentation.
#
# The section anchor matters. demo-app values contains two keys named "host" —
# database.host and ingress.host — and matching the key alone rewrites
# whichever appears first. That works until someone reorders the file, at which
# point the application quietly points at the wrong hostname.
set_yaml_value() {
  local file="$1" section="$2" key="$3" value="$4" quote="${5:-yes}"
  python3 - "$file" "$section" "$key" "$value" "$quote" <<'PYEOF'
import re, sys

path, section, key, value, quote = sys.argv[1:6]
src = open(path).read()
replacement = '"%s"' % value if quote == "yes" else value

start = 0
if section:
    m = re.search(r'^%s:[ \t]*$' % re.escape(section), src, re.MULTILINE)
    if not m:
        sys.exit("section '%s' not found in %s" % (section, path))
    start = m.end()

pattern = re.compile(r'^(\s*)%s:[ \t]*\S.*$' % re.escape(key), re.MULTILINE)
m = pattern.search(src, start)
if not m:
    sys.exit("key '%s' not found under '%s' in %s" % (key, section or "root", path))

src = src[:m.start()] + "%s%s: %s" % (m.group(1), key, replacement) + src[m.end():]
open(path, "w").write(src)
PYEOF
  printf '    %-46s -> %s\n' "${section:+$section.}$key" "$(basename "$file")"
}

log "Updating $(basename "$DEMO_VALUES")"
set_yaml_value "$DEMO_VALUES" database       host             "$DB_HOST"
set_yaml_value "$DEMO_VALUES" externalSecret remoteSecretName "$DB_SECRET_ARN"
set_yaml_value "$DEMO_VALUES" externalSecret roleArn          "$ROLE_SECRETS"
set_yaml_value "$DEMO_VALUES" ingress        certificateArn   "$CERT_ARN"

log "Updating $(basename "$LBC_VALUES")"
set_yaml_value "$LBC_VALUES" ""             vpcId                      "$VPC_ID"  no
set_yaml_value "$LBC_VALUES" serviceAccount eks.amazonaws.com/role-arn "$ROLE_LBC" no

log "Updating $(basename "$DNS_VALUES")"
set_yaml_value "$DNS_VALUES" serviceAccount eks.amazonaws.com/role-arn "$ROLE_DNS" no

log "Updating $(basename "$GRAFANA_VALUES")"
set_yaml_value "$GRAFANA_VALUES" grafana alb.ingress.kubernetes.io/certificate-arn "$CERT_ARN" no

log "Verifying the files still parse"
python3 - "$DEMO_VALUES" "$LBC_VALUES" "$DNS_VALUES" "$GRAFANA_VALUES" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    print("    pyyaml not installed, skipping parse check")
    sys.exit(0)
for path in sys.argv[1:]:
    yaml.safe_load(open(path))
    print("    ok  %s" % path.split("/")[-1])
PYEOF

log "Diff"
git -C "$REPO_ROOT" --no-pager diff --stat -- argocd/ || true

cat <<'EOF'

Review the diff, then:

    git add argocd/
    git commit -m "chore: sync values with rebuilt environment"
    git push
    kubectl -n argocd patch app root --type merge -p '{"operation":{"sync":{}}}'
EOF