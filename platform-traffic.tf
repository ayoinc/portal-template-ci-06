# Traffic into and inside the cluster: ingress controller, certificates, DNS records and the service mesh.

# Ingress controller, one of two. Either one runs two replicas behind a LoadBalancer Service whose cloud-specific
# annotations come from the cluster layer, and registers the default IngressClass of the cluster.

resource "helm_release" "ingress_nginx" {
  count = var.ingress_controller == "nginx" ? 1 : 0

  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = local.platform_chart_versions.ingress_nginx
  namespace  = kubernetes_namespace_v1.platform["ingress"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    controller = {
      replicaCount = 2
      ingressClassResource = {
        default = true
      }
      service = {
        annotations = local.cloud.ingress_service_annotations
      }
      metrics = {
        enabled        = true
        serviceMonitor = { enabled = local.platform_service_monitors }
      }
    }
  })]

  depends_on = [
    terraform_data.cluster_ready,
    # The ServiceMonitor kind is installed by kube-prometheus-stack.
    helm_release.kube_prometheus_stack,
  ]
}

resource "helm_release" "traefik" {
  count = var.ingress_controller == "traefik" ? 1 : 0

  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = local.platform_chart_versions.traefik
  namespace  = kubernetes_namespace_v1.platform["ingress"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    deployment = {
      replicas = 2
    }
    ingressClass = {
      enabled        = true
      isDefaultClass = true
    }
    service = {
      annotations = local.cloud.ingress_service_annotations
    }
    metrics = {
      prometheus = {
        service        = { enabled = local.platform_service_monitors }
        serviceMonitor = { enabled = local.platform_service_monitors }
      }
    }
  })]

  depends_on = [
    terraform_data.cluster_ready,
    # The ServiceMonitor kind is installed by kube-prometheus-stack.
    helm_release.kube_prometheus_stack,
  ]
}

# cert-manager with its custom resource definitions. Issuers are not created here: they need an ACME account
# e-mail address or a CA of the organisation.

resource "helm_release" "cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = local.platform_chart_versions.cert_manager
  namespace  = kubernetes_namespace_v1.platform["cert-manager"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    crds = {
      enabled = true
      # The definitions, and with them every Certificate and Issuer, stay when the release is removed.
      keep = true
    }
    global = {
      # Leader election in the release's own namespace instead of kube-system, which managed clusters restrict.
      leaderElection = { namespace = "cert-manager" }
    }
    prometheus = {
      enabled        = true
      servicemonitor = { enabled = local.platform_service_monitors }
    }
  })]

  depends_on = [
    terraform_data.cluster_ready,
    # The ServiceMonitor kind is installed by kube-prometheus-stack.
    helm_release.kube_prometheus_stack,
  ]
}

# external-dns. The DNS provider, the workload identity of its service account and provider-specific chart values
# come from the cluster layer, which also creates the cloud identity with the DNS permissions.

resource "helm_release" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = local.platform_chart_versions.external_dns
  namespace  = kubernetes_namespace_v1.platform["external-dns"].metadata[0].name
  timeout    = 600

  values = [
    yamlencode({
      provider = {
        name = local.cloud.external_dns.provider
      }
      serviceAccount = {
        create      = true
        name        = "external-dns"
        annotations = local.cloud.external_dns.service_account_annotations
      }
      sources       = ["service", "ingress"]
      domainFilters = var.dns_domain_filters
      # Records are created and updated, never deleted; each record is marked as owned by this cluster so that
      # several clusters can share a zone.
      policy     = "upsert-only"
      registry   = "txt"
      txtOwnerId = local.cloud.cluster_name
      serviceMonitor = {
        enabled = local.platform_service_monitors
      }
    }),
    # Merged over the values above.
    yamlencode(local.cloud.external_dns.values),
  ]

  depends_on = [
    terraform_data.cluster_ready,
    # The ServiceMonitor kind is installed by kube-prometheus-stack.
    helm_release.kube_prometheus_stack,
  ]
}

# Istio control plane: the base chart (custom resource definitions, validation webhook) first, then istiod.
# Workloads join the mesh when their namespace is labelled istio-injection=enabled.

resource "helm_release" "istio_base" {
  count = var.enable_service_mesh ? 1 : 0

  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = local.platform_chart_versions.istio
  namespace  = kubernetes_namespace_v1.platform["istio-system"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    defaultRevision = "default"
  })]

  depends_on = [terraform_data.cluster_ready]
}

resource "helm_release" "istiod" {
  count = var.enable_service_mesh ? 1 : 0

  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = local.platform_chart_versions.istio
  namespace  = kubernetes_namespace_v1.platform["istio-system"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    global = {
      istioNamespace = "istio-system"
    }
    # The chart leaves the seccomp profile unset, which the restricted Pod Security Standard does not accept.
    seccompProfile = { type = "RuntimeDefault" }
  })]

  depends_on = [
    terraform_data.cluster_ready,
    helm_release.istio_base,
  ]
}
