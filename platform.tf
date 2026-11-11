# Platform components that are the same on every cloud. They are installed into the cluster of this stack through
# the kubernetes and helm providers; the cloud-specific settings they need come from local.cloud.
#
# This file holds what the components share: chart versions, namespaces and their Pod Security Standards level.
# The components themselves are in platform-gitops.tf, platform-observability.tf, platform-traffic.tf and
# platform-security.tf.

locals {
  # Exact chart versions. Change a version here to upgrade a component.
  platform_chart_versions = {
    argo_cd                = "10.17.1"
    kube_prometheus_stack  = "93.1.2"
    loki                   = "21.1.3"
    alloy                  = "1.15.0"
    istio                  = "1.30.8"
    cert_manager           = "v1.21.3"
    external_dns           = "1.23.0"
    ingress_nginx          = "4.15.1"
    traefik                = "42.3.2"
    gatekeeper             = "3.23.1"
    vault_secrets_operator = "1.6.2"
  }

  # Every namespace the platform can create, whether its component is enabled, and the Pod Security Standards level
  # the component's pods run under. privileged is used only where pods need access to the node itself.
  platform_namespace_catalog = {
    argocd = {
      enabled      = var.enable_gitops
      pod_security = "restricted"
      labels       = {}
    }
    # The node exporter uses the host network and file systems; the log collector reads /var/log of the node.
    monitoring = {
      enabled      = var.enable_observability
      pod_security = "privileged"
      labels       = {}
    }
    istio-system = {
      enabled      = var.enable_service_mesh
      pod_security = "restricted"
      labels       = {}
    }
    cert-manager = {
      enabled      = var.enable_cert_manager
      pod_security = "restricted"
      labels       = {}
    }
    external-dns = {
      enabled      = var.enable_external_dns
      pod_security = "restricted"
      labels       = {}
    }
    ingress = {
      enabled      = var.ingress_controller != "none"
      pod_security = "restricted"
      labels       = {}
    }
    # The label keeps Gatekeeper's own namespace out of its admission webhook, so a broken policy cannot stop
    # Gatekeeper from starting.
    gatekeeper-system = {
      enabled      = var.enable_opa
      pod_security = "restricted"
      labels       = { "admission.gatekeeper.sh/ignore" = "no-self-managing" }
    }
    vault = {
      enabled      = var.enable_vault_integration
      pod_security = "restricted"
      labels       = {}
    }
  }

  platform_namespaces = { for name, ns in local.platform_namespace_catalog : name => ns if ns.enabled }

  # Prometheus Operator resources (ServiceMonitor) exist only when the observability stack is installed.
  platform_service_monitors = var.enable_observability
}

resource "kubernetes_namespace_v1" "platform" {
  for_each = local.platform_namespaces

  metadata {
    name = each.key

    labels = merge(
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "${var.project_name}-${var.environment}"
      },
      each.value.labels,
      var.enable_pod_security_standards ? {
        "pod-security.kubernetes.io/enforce"         = each.value.pod_security
        "pod-security.kubernetes.io/enforce-version" = "latest"
        "pod-security.kubernetes.io/audit"           = each.value.pod_security
        "pod-security.kubernetes.io/audit-version"   = "latest"
        "pod-security.kubernetes.io/warn"            = each.value.pod_security
        "pod-security.kubernetes.io/warn-version"    = "latest"
      } : {},
    )
  }

  depends_on = [terraform_data.cluster_ready]
}
