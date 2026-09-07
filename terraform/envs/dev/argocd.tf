###############################################################################
# Terraform installs Argo CD and one root Application; Argo delivers everything
# else from Git. More helm_release resources here would mean two systems both
# owning in-cluster state.
###############################################################################

# exec credentials rather than a stored token: an EKS token expires long before
# the next apply, and a stored one would put a credential in state.
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.region,
      ]
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [file("${path.module}/values/argocd.yaml")]

  # Wait, or the root Application below is applied before its CRD exists.
  wait          = true
  wait_for_jobs = true
  timeout       = 900

  # Needs nodes to schedule on.
  depends_on = [module.eks]
}

# Root of the app-of-apps tree. Every other Application is discovered from
# argocd/argo-manifests/, so adding a component is a PR, not a Terraform change.
#
# Packaged as a local Helm chart because kubernetes_manifest needs the cluster
# reachable at plan time, which breaks plan on a clean environment.
resource "helm_release" "root_app" {
  name      = "root-app"
  namespace = "argocd"

  chart = "${path.module}/../../../argocd/bootstrap"

  set {
    name  = "repoURL"
    value = var.gitops_repo_url
  }

  set {
    name  = "targetRevision"
    value = var.gitops_target_revision
  }

  depends_on = [helm_release.argocd]
}
