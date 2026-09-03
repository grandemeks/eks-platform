###############################################################################
# Argo CD bootstrap
#
# Terraform installs exactly two things into the cluster: Argo CD, and a single
# root Application. Everything else — the load balancer controller, External
# Secrets, the observability stack, the demo application — is delivered by Argo
# from Git.
#
# The boundary is deliberate. Terraform owns AWS; Argo owns the cluster. Adding
# more helm_release resources here would mean two systems both believing they
# own in-cluster state, and a drift problem with no clear owner.
###############################################################################

# Credentials are produced by running `aws eks get-token` at apply time rather
# than being read once and written into state. A token has a short lifetime, so
# a stored one would be expired by the next apply — and state would then contain
# a credential, which is exactly what the rest of this repository avoids.
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

  # The chart installs CRDs and several controllers; without waiting, the root
  # Application below would be applied against a cluster where the Application
  # CRD does not yet exist.
  wait          = true
  wait_for_jobs = true
  timeout       = 900

  # Argo CD cannot be installed until there are nodes to schedule it on.
  depends_on = [module.eks]
}

# The root of the app-of-apps tree, and the only Application Terraform creates.
# It points Argo at argocd/argo-manifests/ in this repository; every other
# Application is discovered from there, so adding a component becomes a pull
# request rather than a Terraform change.
#
# It is packaged as a minimal local Helm chart purely so the helm provider can
# apply it. The alternative, kubernetes_manifest, requires the cluster to be
# reachable at plan time — which it is not when the cluster does not yet exist,
# breaking plan on a clean environment.
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
