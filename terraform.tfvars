# Values chosen in the portal when this repository was created.

project_name       = "orbit"
environment        = "dev"
region             = "eu-west-1"
kubernetes_version = "1.36"

node_min_count = 3
node_max_count = 10
node_size      = "medium"

# Platform components
enable_gitops                 = true
enable_observability          = true
enable_service_mesh           = false
enable_cert_manager           = true
enable_external_dns           = true
ingress_controller            = "traefik"
enable_pod_security_standards = true
enable_network_policies       = true
enable_opa                    = false
enable_vault_integration      = false
