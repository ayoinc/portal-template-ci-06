# The cluster autoscaler adds nodes when pods do not fit and removes nodes that are no longer needed, between
# node_min_count and node_max_count. It finds the node group through the tags EKS puts on its Auto Scaling group.

locals {
  # The autoscaler simulates the scheduler, so its release follows the Kubernetes minor version of the cluster.
  # A version that is not listed uses the first autoscaler release of that minor version.
  cluster_autoscaler_image_tags = {
    "1.35" = "v1.35.3"
    "1.36" = "v1.36.2"
    "1.37" = "v1.37.0"
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    fullnameOverride = "cluster-autoscaler"
    cloudProvider    = "aws"
    awsRegion        = var.region

    autoDiscovery = {
      clusterName = module.eks.cluster_name
    }

    image = {
      tag = lookup(local.cluster_autoscaler_image_tags, var.kubernetes_version, "v${var.kubernetes_version}.0")
    }

    rbac = {
      serviceAccount = {
        name = "cluster-autoscaler"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
        }
      }
    }

    extraArgs = {
      balance-similar-node-groups = true
      skip-nodes-with-system-pods = false
    }
  })]

  depends_on = [
    terraform_data.cluster_ready,
    aws_iam_role_policy.cluster_autoscaler,
  ]
}
