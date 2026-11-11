# What the platform layer installed. Service names are the in-cluster names used with kubectl port-forward;
# docs/components.md has the commands.

output "platform_namespaces" {
  description = "Namespaces created for the platform components, with the Pod Security Standards level each one is labelled with (null when the labels are switched off)."
  value = {
    for name, ns in local.platform_namespaces :
    kubernetes_namespace_v1.platform[name].metadata[0].name => var.enable_pod_security_standards ? ns.pod_security : null
  }
}

output "platform_chart_versions" {
  description = "Helm chart version of every installed platform component."
  value = merge(
    var.enable_gitops ? { argo-cd = one(helm_release.argocd[*].version) } : {},
    var.enable_observability ? {
      kube-prometheus-stack = one(helm_release.kube_prometheus_stack[*].version)
      loki                  = one(helm_release.loki[*].version)
      alloy                 = one(helm_release.alloy[*].version)
    } : {},
    var.enable_service_mesh ? {
      istio-base = one(helm_release.istio_base[*].version)
      istiod     = one(helm_release.istiod[*].version)
    } : {},
    var.enable_cert_manager ? { cert-manager = one(helm_release.cert_manager[*].version) } : {},
    var.enable_external_dns ? { external-dns = one(helm_release.external_dns[*].version) } : {},
    var.ingress_controller == "nginx" ? { ingress-nginx = one(helm_release.ingress_nginx[*].version) } : {},
    var.ingress_controller == "traefik" ? { traefik = one(helm_release.traefik[*].version) } : {},
    var.enable_opa ? { gatekeeper = one(helm_release.gatekeeper[*].version) } : {},
    var.enable_vault_integration ? { vault-secrets-operator = one(helm_release.vault_secrets_operator[*].version) } : {},
  )
}

output "platform_services" {
  description = "Services of the installed components as namespace/name, for kubectl port-forward or an Ingress backend."
  value = merge(
    var.enable_gitops ? { argocd = "argocd/argocd-server" } : {},
    var.enable_observability ? {
      grafana      = "monitoring/kube-prometheus-stack-grafana"
      prometheus   = "monitoring/kube-prometheus-stack-prometheus"
      alertmanager = "monitoring/kube-prometheus-stack-alertmanager"
      loki         = "monitoring/loki"
    } : {},
    var.enable_service_mesh ? { istiod = "istio-system/istiod" } : {},
    var.ingress_controller == "nginx" ? { ingress = "ingress/ingress-nginx-controller" } : {},
    var.ingress_controller == "traefik" ? { ingress = "ingress/traefik" } : {},
  )
}

output "platform_ingress_class" {
  description = "Name of the default IngressClass, or null when no ingress controller is installed."
  value       = var.ingress_controller == "none" ? null : var.ingress_controller
}

output "platform_network_policies" {
  description = "Whether the platform namespaces have NetworkPolicy objects, and whether the cluster enforces them."
  value = {
    created  = var.enable_network_policies
    enforced = var.enable_network_policies && local.cloud.network_policy_enforced
    policies = concat(
      [for name in keys(kubernetes_network_policy_v1.default_deny_ingress) : "${name}/default-deny-ingress"],
      [for name in keys(kubernetes_network_policy_v1.allow_same_namespace) : "${name}/allow-same-namespace"],
      [for name in keys(kubernetes_network_policy_v1.allow_prometheus_scrape) : "${name}/allow-prometheus-scrape"],
      [for name, policy in kubernetes_network_policy_v1.allow : "${policy.metadata[0].namespace}/allow-${name}"],
    )
  }
}
