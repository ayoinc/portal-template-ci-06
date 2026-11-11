# Security: admission policies (OPA Gatekeeper), secrets from Vault (Vault Secrets Operator) and the network
# policies of the platform namespaces. The Pod Security Standards labels are set on the namespaces in platform.tf.

resource "helm_release" "gatekeeper" {
  count = var.enable_opa ? 1 : 0

  name       = "gatekeeper"
  repository = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart      = "gatekeeper"
  version    = local.platform_chart_versions.gatekeeper
  namespace  = kubernetes_namespace_v1.platform["gatekeeper-system"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    # The chart's hook jobs would label the namespace themselves. The labels are set on the namespace resource
    # instead, so that Terraform stays the only writer of them.
    postInstall = { labelNamespace = { enabled = false } }
    postUpgrade = { labelNamespace = { enabled = false } }
  })]

  depends_on = [terraform_data.cluster_ready]
}

resource "helm_release" "vault_secrets_operator" {
  count = var.enable_vault_integration ? 1 : 0

  name       = "vault-secrets-operator"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault-secrets-operator"
  version    = local.platform_chart_versions.vault_secrets_operator
  namespace  = kubernetes_namespace_v1.platform["vault"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    # The VaultConnection and VaultAuth objects named default, used by every secret that does not name its own.
    defaultVaultConnection = {
      enabled = true
      address = var.vault_address
    }
    defaultAuthMethod = {
      enabled = true
      method  = "kubernetes"
      mount   = var.vault_kubernetes_auth_mount
      kubernetes = {
        role           = var.vault_kubernetes_auth_role
        serviceAccount = "default"
      }
    }
    # The chart's defaults plus what the restricted Pod Security Standard asks for. Applies to the operator and to
    # the chart's upgrade and cleanup jobs.
    controller = {
      podSecurityContext = {
        runAsNonRoot   = true
        seccompProfile = { type = "RuntimeDefault" }
      }
      securityContext = {
        allowPrivilegeEscalation = false
        capabilities             = { drop = ["ALL"] }
      }
    }
    telemetry = {
      serviceMonitor = { enabled = local.platform_service_monitors }
    }
    # The pod of "helm test", which Terraform never runs.
    tests = { enabled = false }
  })]

  depends_on = [
    terraform_data.cluster_ready,
    # The ServiceMonitor kind is installed by kube-prometheus-stack.
    helm_release.kube_prometheus_stack,
  ]
}

# Network policies. Every platform namespace denies ingress by default; the rules below open what the components
# need. Egress is not restricted. The policies take effect when the cluster enforces NetworkPolicy
# (local.cloud.network_policy_enforced).

locals {
  platform_policy_namespaces = var.enable_network_policies ? local.platform_namespaces : {}

  # Allow rules on top of default-deny. A rule without "from" admits every source: the Kubernetes API server
  # calls admission webhooks from outside the pod network, and its address differs per cloud.
  # ports are container ports (number or name); pod_labels selects the pods the rule applies to.
  platform_ingress_rules = {
    argocd-server-from-ingress = {
      enabled    = var.enable_gitops && var.ingress_controller != "none"
      namespace  = "argocd"
      pod_labels = { "app.kubernetes.io/name" = "argocd-server" }
      from       = "ingress"
      ports      = ["8080"]
    }
    grafana-from-ingress = {
      enabled    = var.enable_observability && var.ingress_controller != "none"
      namespace  = "monitoring"
      pod_labels = { "app.kubernetes.io/name" = "grafana" }
      from       = "ingress"
      ports      = ["3000"]
    }
    prometheus-operator-webhook = {
      enabled    = var.enable_observability
      namespace  = "monitoring"
      pod_labels = { "app.kubernetes.io/name" = "kube-prometheus-stack-prometheus-operator" }
      from       = "anywhere"
      ports      = ["10250"]
    }
    cert-manager-webhook = {
      enabled    = var.enable_cert_manager
      namespace  = "cert-manager"
      pod_labels = { "app.kubernetes.io/name" = "webhook" }
      from       = "anywhere"
      ports      = ["10250"]
    }
    ingress-nginx-traffic = {
      enabled    = var.ingress_controller == "nginx"
      namespace  = "ingress"
      pod_labels = { "app.kubernetes.io/name" = "ingress-nginx", "app.kubernetes.io/component" = "controller" }
      from       = "anywhere"
      ports      = ["80", "443", "8443"]
    }
    traefik-traffic = {
      enabled    = var.ingress_controller == "traefik"
      namespace  = "ingress"
      pod_labels = { "app.kubernetes.io/name" = "traefik" }
      from       = "anywhere"
      ports      = ["8000", "8443"]
    }
    istiod-discovery-and-webhook = {
      enabled    = var.enable_service_mesh
      namespace  = "istio-system"
      pod_labels = { "app" = "istiod" }
      from       = "anywhere"
      ports      = ["15010", "15012", "15017"]
    }
    gatekeeper-webhook = {
      enabled    = var.enable_opa
      namespace  = "gatekeeper-system"
      pod_labels = { "control-plane" = "controller-manager" }
      from       = "anywhere"
      ports      = ["8443"]
    }
  }

  platform_enabled_ingress_rules = {
    for name, rule in local.platform_ingress_rules : name => rule
    if var.enable_network_policies && rule.enabled
  }
}

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  for_each = local.platform_policy_namespaces

  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.platform[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }

  depends_on = [terraform_data.cluster_ready]
}

# Pods of one component talk to each other (Argo CD to its Redis, Grafana to Prometheus and Loki, ...).
resource "kubernetes_network_policy_v1" "allow_same_namespace" {
  for_each = local.platform_policy_namespaces

  metadata {
    name      = "allow-same-namespace"
    namespace = kubernetes_namespace_v1.platform[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = each.key }
        }
      }
    }
  }

  depends_on = [terraform_data.cluster_ready]
}

# Prometheus scrapes the metrics endpoints of the other platform namespaces.
resource "kubernetes_network_policy_v1" "allow_prometheus_scrape" {
  for_each = var.enable_observability ? { for name, ns in local.platform_policy_namespaces : name => ns if name != "monitoring" } : {}

  metadata {
    name      = "allow-prometheus-scrape"
    namespace = kubernetes_namespace_v1.platform[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "prometheus" }
        }
      }
    }
  }

  depends_on = [terraform_data.cluster_ready]
}

resource "kubernetes_network_policy_v1" "allow" {
  for_each = local.platform_enabled_ingress_rules

  metadata {
    name      = "allow-${each.key}"
    namespace = kubernetes_namespace_v1.platform[each.value.namespace].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = each.value.pod_labels
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = each.value.from == "ingress" ? [1] : []

        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = "ingress" }
          }
        }
      }

      dynamic "ports" {
        for_each = each.value.ports

        content {
          port     = ports.value
          protocol = "TCP"
        }
      }
    }
  }

  depends_on = [terraform_data.cluster_ready]
}
