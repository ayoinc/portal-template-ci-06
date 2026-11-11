# Platform components

The cluster is delivered with a set of platform components. Terraform installs them with Helm right after the cluster is ready (`platform.tf` and `platform-*.tf`), in namespaces it creates itself. Each component is switched by one value in `terraform.tfvars`; change the value, open a pull request, and the pipeline's plan shows what will be installed or removed.

How to get `kubectl` access to the cluster is described in the [Overview](index.md).

## What this repository was created with

| Component                         | Setting in `terraform.tfvars`   | Value                                                |
| --------------------------------- | ------------------------------- | ---------------------------------------------------- |
| GitOps (Argo CD)                  | `enable_gitops`                 | on              |
| Observability (Prometheus, Grafana, Loki) | `enable_observability`  | on       |
| Service mesh (Istio)              | `enable_service_mesh`           | off         |
| cert-manager                      | `enable_cert_manager`           | on         |
| external-dns                      | `enable_external_dns`           | on         |
| Ingress controller                | `ingress_controller`            | traefik                                |
| Pod Security Standards            | `enable_pod_security_standards` | on |
| Network policies                  | `enable_network_policies`       | on     |
| OPA Gatekeeper                    | `enable_opa`                    | off                 |
| Vault integration                 | `enable_vault_integration`      | off    |

The sections below describe the components that are switched on. A component that is off has no namespace, no Helm release and no network policy; switching it on later adds them, and this page lists every component with its chart at the end.

`terraform output platform_chart_versions`, `platform_namespaces` and `platform_services` show what is installed at any time.

## GitOps: Argo CD

- **Installed:** chart `argo-cd` 10.17.1 (Argo CD v3.6.1) from `https://argoproj.github.io/argo-helm`, release `argocd`, namespace `argocd`: API server and UI, application controller, repo server, ApplicationSet and notifications controllers, Dex and Redis.
- **Reach it:**

    ```bash
    kubectl -n argocd port-forward svc/argocd-server 8080:443
    ```

    Open <https://localhost:8080> (the certificate is self-signed) and sign in as `admin`. Argo CD generates the password on first start:

    ```bash
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
    ```

    Change the password after the first login and delete that Secret; no password is stored in this repository.
- **Toggle:** `enable_gitops = false` removes Argo CD and its namespace, including the `Application` objects stored in it. Workloads they deployed keep running but are no longer synchronised. Delete applications that carry the `resources-finalizer.argocd.argoproj.io` finalizer beforehand; without the controller nothing clears it and the namespace cannot be removed.

## Observability: Prometheus, Alertmanager, Grafana, Loki

- **Installed**, all in namespace `monitoring`:
    - chart `kube-prometheus-stack` 93.1.2 from `https://prometheus-community.github.io/helm-charts`, release `kube-prometheus-stack`: Prometheus Operator, one Prometheus (metrics kept for 15 days on a 50 GiB volume), Alertmanager, Grafana (10 GiB volume), node exporter and kube-state-metrics, with the default dashboards and alert rules. The control plane targets a managed cluster does not expose are switched off.
    - chart `loki` 21.1.3 (Loki 3.7.9) from `https://grafana-community.github.io/helm-charts`, release `loki`: a single Loki process that keeps logs for 7 days on a 20 GiB volume.
    - chart `alloy` 1.15.0 (Grafana Alloy v1.21.3) from `https://grafana.github.io/helm-charts`, release `alloy`: a DaemonSet that tails the container logs of every node and sends them to Loki with the labels `namespace`, `pod`, `container`, `app`, `node` and `cluster`.

    Volumes use the storage class the cluster layer provides. Retention and volume sizes are the variables `prometheus_retention`, `prometheus_storage_size`, `loki_retention` and `loki_storage_size`.
- **Reach it:**

    ```bash
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
    ```

    Open <http://localhost:3000> and sign in as `admin`. The chart generates the password:

    ```bash
    kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
    ```

    Grafana has the data sources Prometheus, Alertmanager and Loki. Logs are under **Explore**, data source **Loki**, for example the query `{namespace="kube-system"}`.

    ```bash
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
    kubectl -n monitoring port-forward svc/loki 3100:3100
    ```

- **Metrics of the other components:** Prometheus picks up every `ServiceMonitor`, `PodMonitor` and `PrometheusRule` in the cluster, so applications only need to create one. The platform components that are switched on are scraped as well.
- **Alerts** are evaluated but not sent anywhere: add receivers (Slack, e-mail, PagerDuty) with an `AlertmanagerConfig` object or the chart value `alertmanager.config`.
- **Toggle:** `enable_observability = false` removes the three releases and the namespace, and the other components stop creating `ServiceMonitor` objects. The volume claims are deleted with the namespace, so the stored metrics, logs and Grafana changes are lost.

## Certificates: cert-manager

- **Installed:** chart `cert-manager` v1.21.3 from `https://charts.jetstack.io`, release `cert-manager`, namespace `cert-manager`: controller, webhook and CA injector, with the custom resource definitions installed by the chart.
- **Use it:** no issuer is created, because an issuer needs an e-mail address or a CA of your organisation. A Let's Encrypt issuer that answers HTTP-01 challenges through the ingress controller:

    ```yaml
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt
    spec:
      acme:
        server: https://acme-v02.api.letsencrypt.org/directory
        email: platform@example.com
        privateKeySecretRef:
          name: letsencrypt-account-key
        solvers:
          - http01:
              ingress:
                ingressClassName: traefik
    ```

    An Ingress then asks for a certificate with the annotation `cert-manager.io/cluster-issuer: letsencrypt` and a `tls` section.

    ```bash
    kubectl get clusterissuers,certificates -A
    ```

- **Toggle:** `enable_cert_manager = false` removes the release and the namespace. The custom resource definitions, and with them existing `Certificate` objects and their Secrets, are kept on purpose; certificates are no longer renewed.

## DNS records: external-dns

- **Installed:** chart `external-dns` 1.23.0 from `https://kubernetes-sigs.github.io/external-dns`, release `external-dns`, namespace `external-dns`. It runs as the service account `external-dns`, which the cluster layer binds to a cloud identity that may change DNS records (see the [Overview](index.md)).
- **Use it:** give an Ingress a host name, or a LoadBalancer Service the annotation `external-dns.alpha.kubernetes.io/hostname`, in a DNS zone the identity can change. Records are created and updated, never deleted (`upsert-only`), and are marked with a TXT record that names this cluster as owner.

    ```bash
    kubectl -n external-dns logs deployment/external-dns
    ```

    Limit the zones with the variable `dns_domain_filters`, for example `dns_domain_filters = ["example.com"]`.
- **Toggle:** `enable_external_dns = false` removes the release, the namespace and the cloud identity. Existing DNS records stay.

## Ingress controller: Traefik

- **Installed:** chart `traefik` 42.3.2 (Traefik v3.7.17) from `https://traefik.github.io/charts`, release `traefik`, namespace `ingress`: two replicas behind a Service of type LoadBalancer (ports 80 and 443), and the IngressClass `traefik`, which is the default class of the cluster. Traefik serves `Ingress` objects and its own `IngressRoute` objects.
- **Reach it:** the address of the cloud load balancer is on the Service. Point DNS at it, or let external-dns do that.

    ```bash
    kubectl -n ingress get service traefik
    ```

- **Toggle:** `ingress_controller` is `nginx`, `traefik` or `none`. Changing it replaces the controller and its load balancer, so the public address changes; `none` removes the controller and the namespace `ingress`.

## Pod Security Standards

`enable_pod_security_standards` is **on**. When on, every namespace above carries the labels `pod-security.kubernetes.io/enforce`, `audit` and `warn` with the strictest level its component runs under, and the API server rejects pods that ask for more:

| Namespace           | Level        | Why                                                                                         |
| ------------------- | ------------ | ------------------------------------------------------------------------------------------- |
| `argocd`            | `restricted` |                                                                                             |
| `monitoring`        | `privileged` | The node exporter uses the host network and file systems; Alloy reads `/var/log` of the node |
| `istio-system`      | `restricted` |                                                                                             |
| `cert-manager`      | `restricted` |                                                                                             |
| `external-dns`      | `restricted` |                                                                                             |
| `ingress`           | `restricted` |                                                                                             |
| `gatekeeper-system` | `restricted` |                                                                                             |
| `vault`             | `restricted` |                                                                                             |

When off, the namespaces have no such labels and the cluster's default (no enforcement) applies. Namespaces of your own applications are not created by this stack; label them the same way, `restricted` unless a workload needs more.

## Network policies

`enable_network_policies` is **on**. When on, the cluster layer switches on NetworkPolicy enforcement and every namespace above gets:

- `default-deny-ingress`: no pod accepts connections unless another policy allows them;
- `allow-same-namespace`: the pods of one component reach each other;
- `allow-prometheus-scrape`: Prometheus reaches the metrics endpoints (only with observability on);
- the rules the component needs from outside its namespace:

| Policy                               | Namespace           | Opens                                                                 |
| ------------------------------------ | ------------------- | --------------------------------------------------------------------- |
| `allow-ingress-nginx-traffic`        | `ingress`           | HTTP, HTTPS and the admission webhook of ingress-nginx, from anywhere |
| `allow-traefik-traffic`              | `ingress`           | HTTP and HTTPS of Traefik, from anywhere                              |
| `allow-argocd-server-from-ingress`   | `argocd`            | The Argo CD server, from the ingress controller                       |
| `allow-grafana-from-ingress`         | `monitoring`        | Grafana, from the ingress controller                                  |
| `allow-prometheus-operator-webhook`  | `monitoring`        | The operator's admission webhook, called by the API server            |
| `allow-cert-manager-webhook`         | `cert-manager`      | The admission webhook, called by the API server                       |
| `allow-istiod-discovery-and-webhook` | `istio-system`      | Sidecar configuration (15010, 15012) and the injection webhook (15017) |
| `allow-gatekeeper-webhook`           | `gatekeeper-system` | The admission webhook, called by the API server                       |

Outgoing connections are not restricted, and `kubectl port-forward` keeps working because it does not pass through the pod network. Namespaces of your own applications get no policy from this stack. `terraform output platform_network_policies` lists the policies and says whether the cluster enforces them.

## All components and their charts

The chart versions are pinned in `platform.tf` (`local.platform_chart_versions`). To upgrade a component, change its version there, read the chart's upgrade notes, and let the pipeline plan and apply the change.

| Setting                         | Chart (repository)                                                      | Version           | Namespace           |
| ------------------------------- | ----------------------------------------------------------------------- | ----------------- | ------------------- |
| `enable_gitops`                 | `argo-cd` (`https://argoproj.github.io/argo-helm`)                      | 10.17.1           | `argocd`            |
| `enable_observability`          | `kube-prometheus-stack` (`https://prometheus-community.github.io/helm-charts`) | 93.1.2     | `monitoring`        |
| `enable_observability`          | `loki` (`https://grafana-community.github.io/helm-charts`)              | 21.1.3            | `monitoring`        |
| `enable_observability`          | `alloy` (`https://grafana.github.io/helm-charts`)                       | 1.15.0            | `monitoring`        |
| `enable_service_mesh`           | `base`, `istiod` (`https://istio-release.storage.googleapis.com/charts`) | 1.30.8           | `istio-system`      |
| `enable_cert_manager`           | `cert-manager` (`https://charts.jetstack.io`)                           | v1.21.3           | `cert-manager`      |
| `enable_external_dns`           | `external-dns` (`https://kubernetes-sigs.github.io/external-dns`)       | 1.23.0            | `external-dns`      |
| `ingress_controller = "nginx"`  | `ingress-nginx` (`https://kubernetes.github.io/ingress-nginx`)          | 4.15.1            | `ingress`           |
| `ingress_controller = "traefik"` | `traefik` (`https://traefik.github.io/charts`)                         | 42.3.2            | `ingress`           |
| `enable_opa`                    | `gatekeeper` (`https://open-policy-agent.github.io/gatekeeper/charts`)  | 3.23.1            | `gatekeeper-system` |
| `enable_vault_integration`      | `vault-secrets-operator` (`https://helm.releases.hashicorp.com`)        | 1.6.2             | `vault`             |

Settings without a form field, set in `terraform.tfvars` when the default does not fit:

| Variable                      | Default                                     | Meaning                                                    |
| ----------------------------- | ------------------------------------------- | ---------------------------------------------------------- |
| `dns_domain_filters`          | `[]`                                        | DNS zones external-dns may manage; empty means every zone its identity can change |
| `vault_address`               | `http://vault.vault.svc.cluster.local:8200` | Vault server of the Vault Secrets Operator                 |
| `vault_kubernetes_auth_mount` | `kubernetes`                                | Mount of the Kubernetes auth method in Vault               |
| `vault_kubernetes_auth_role`  | `vault-secrets-operator`                    | Vault role of the default `VaultAuth` object               |
| `prometheus_retention`        | `15d`                                       | How long Prometheus keeps metrics                          |
| `prometheus_storage_size`     | `50Gi`                                      | Volume of Prometheus                                       |
| `loki_retention`              | `168h`                                      | How long Loki keeps logs                                   |
| `loki_storage_size`           | `20Gi`                                      | Volume of Loki                                             |

On a cluster whose control plane reaches the nodes through a firewall (a private GKE cluster, for example), the admission webhooks listen on these pod ports: cert-manager and the Prometheus Operator 10250, ingress-nginx and Gatekeeper 8443, istiod 15017.
