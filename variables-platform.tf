# Platform components installed into the cluster. The values chosen in the form are in terraform.tfvars.

variable "enable_gitops" {
  description = "Install Argo CD for GitOps deployments."
  type        = bool
}

variable "enable_observability" {
  description = "Install Prometheus, Alertmanager and Grafana (kube-prometheus-stack), Loki and the Alloy log collector."
  type        = bool
}

variable "enable_service_mesh" {
  description = "Install the Istio control plane (base and istiod)."
  type        = bool
}

variable "enable_cert_manager" {
  description = "Install cert-manager and its custom resource definitions."
  type        = bool
}

variable "enable_external_dns" {
  description = "Install external-dns, which publishes Service and Ingress host names in the cloud DNS service."
  type        = bool
}

variable "ingress_controller" {
  description = "Ingress controller to install: nginx (ingress-nginx), traefik or none."
  type        = string

  validation {
    condition     = contains(["nginx", "traefik", "none"], var.ingress_controller)
    error_message = "ingress_controller must be nginx, traefik or none."
  }
}

variable "enable_pod_security_standards" {
  description = "Label every namespace of the platform with the Pod Security Standards level its component runs under."
  type        = bool
}

variable "enable_network_policies" {
  description = "Create a default-deny ingress NetworkPolicy in every namespace of the platform, plus the allow rules its component needs."
  type        = bool
}

variable "enable_opa" {
  description = "Install OPA Gatekeeper for admission policies."
  type        = bool
}

variable "enable_vault_integration" {
  description = "Install the Vault Secrets Operator, connected to the Vault server at vault_address."
  type        = bool
}

# Settings that are not part of the form.

variable "dns_domain_filters" {
  description = "DNS zones external-dns may manage, for example [\"example.com\"]. Empty: every zone its identity can change."
  type        = list(string)
  default     = []
}

variable "vault_address" {
  description = "Address of the Vault server the Vault Secrets Operator reads secrets from. The default is a Vault server installed in the cluster as release vault in namespace vault."
  type        = string
  default     = "http://vault.vault.svc.cluster.local:8200"

  validation {
    condition     = can(regex("^https?://[^/]+", var.vault_address))
    error_message = "vault_address must be an http:// or https:// URL."
  }
}

variable "vault_kubernetes_auth_mount" {
  description = "Mount path of the Kubernetes auth method in Vault that workloads of this cluster log in through."
  type        = string
  default     = "kubernetes"
}

variable "vault_kubernetes_auth_role" {
  description = "Vault role of the default VaultAuth object. It is bound, in Vault, to the service accounts that may read secrets."
  type        = string
  default     = "vault-secrets-operator"
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps metrics."
  type        = string
  default     = "15d"
}

variable "prometheus_storage_size" {
  description = "Size of the persistent volume of Prometheus."
  type        = string
  default     = "50Gi"
}

variable "loki_retention" {
  description = "How long Loki keeps logs. A multiple of 24h."
  type        = string
  default     = "168h"
}

variable "loki_storage_size" {
  description = "Size of the persistent volume of Loki."
  type        = string
  default     = "20Gi"
}
