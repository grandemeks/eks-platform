# eks-platform
AWS Infrastructure with EKS and RDS with Observability

# eks-platform

Reference SRE platform on AWS EKS, built for a take-home assessment: VPC, EKS, RDS and a demo application, deployed through GitOps, observed end to end, and shipped through a CI/CD pipeline with a signed release.

Terraform provisions AWS. Argo CD owns the cluster. The pipeline never touches the cluster directly — it builds, scans, signs, and commits; Argo reconciles from Git.

## Architecture

````mermaid
%% flowchart
````

Live at `https://incode-demo.grandemeks.tech` when the environment is up (see Quick start).

## Stack

| Layer | Tool |
|---|---|
| Infrastructure | Terraform, two stacks: `bootstrap` (persistent) and `envs/dev` (ephemeral) |
| Container orchestration | EKS 1.35, hand-written modules (network, eks, database, irsa-role) |
| GitOps | Argo CD, app-of-apps pattern |
| Ingress / DNS | AWS Load Balancer Controller, external-dns, ACM |
| Secrets | External Secrets Operator, RDS-managed master password, per-namespace IRSA |
| Observability | kube-prometheus-stack, Loki, Tempo, one OpenTelemetry Collector (DaemonSet) |
| CI/CD | GitHub Actions, OIDC federation, Cosign keyless signing |

## Repository layout

````
terraform/
  bootstrap/        state bucket, KMS key, DNS zone, ECR, ACM cert, CI OIDC roles
  envs/dev/         VPC, EKS, RDS, IRSA roles, Argo CD bootstrap
  modules/          network, eks, database, irsa-role
app/                Go demo service — RED metrics, OTel traces, structured logs
helm-charts/
  demo-app/         the only chart written by hand; values.yaml + values-dev.yaml
argocd/
  bootstrap/        the single Application Terraform creates (app-of-apps root)
  argo-manifests/   every other Application, discovered from here
  configs/          values files per Application
scripts/
  teardown.sh       ordered drain + destroy + orphan sweep + verification
  sync-values.sh    copies Terraform outputs into argocd/configs after a rebuild
.github/workflows/
  pr-checks.yml     plan, helm lint, secret scan — no apply path
  environment.yml   the only workflow that touches infrastructure
  app-release.yml   build, scan, sign, commit — no cluster credentials
docs/
  decisions.md      every design decision, the alternative considered, and why
````

## Quick start

````bash
# Bring the environment up (Actions → environment → workflow_dispatch → up)
# or locally:
cd terraform/bootstrap && terraform apply   # first time only
cd ../envs/dev && terraform apply

# Point kubectl at it
aws eks update-kubeconfig --name eks-platform-dev --region eu-central-1

# A rebuilt environment gets a new RDS secret, a new VPC id, new IRSA ARNs.
# Argo reads desired state from Git, so sync and commit them:
./scripts/sync-values.sh
git add argocd/ && git commit -m "chore: sync values" && git push
kubectl -n argocd patch app root --type merge -p '{"operation":{"sync":{}}}'

# Tear down when done — ordered, not a bare terraform destroy
./scripts/teardown.sh
````

The bootstrap layer (state, KMS key, DNS zone, ECR, certificate, CI roles) is left running between sessions — about $1.50/month. Everything else is destroyed.

## Why two Terraform stacks

`bootstrap` holds what must survive a teardown: state, the DNS delegation, the ECR repository with pushed images, the ACM certificate. `envs/dev` holds what gets destroyed nightly: the VPC, the cluster, the database. Separate state files in the same S3 bucket mean a `destroy` in one can never reach the other.

## Why Terraform never touches the cluster beyond Argo CD itself

Argo CD is the one component Terraform installs with `helm_release`, because it's the thing that makes everything else declarative. Every other component — the load balancer controller, External Secrets, the observability stack, the application — is an Argo CD `Application` discovered from `argocd/argo-manifests/`. Adding a component is a pull request, not a Terraform change.

## Documentation

`docs/decisions.md` is the detailed record: every design decision, the alternatives considered, the trade-offs, and the bugs that surfaced only when building the whole environment from scratch. That document is the source of truth for anything not covered here.