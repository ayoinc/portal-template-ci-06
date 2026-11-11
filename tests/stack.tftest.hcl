# Plans the stack against mocked providers, so the tests need no AWS account and no cluster.
# Values not set in a run come from terraform.tfvars.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

mock_provider "tls" {}

mock_provider "kubernetes" {}

mock_provider "helm" {}

run "configured_values" {
  command = plan

  assert {
    condition     = module.eks.cluster_name == local.cluster_name
    error_message = "local.cluster_name must follow the name the eks module gives the cluster."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.name == "/aws/eks/${module.eks.cluster_name}/cluster"
    error_message = "The log group must have the name EKS writes the control plane logs to."
  }

  assert {
    condition = (
      aws_eks_node_group.default.scaling_config[0].min_size == var.node_min_count &&
      aws_eks_node_group.default.scaling_config[0].desired_size == var.node_min_count &&
      aws_eks_node_group.default.scaling_config[0].max_size == max(var.node_min_count, var.node_max_count)
    )
    error_message = "The node group starts at node_min_count and scales up to node_max_count."
  }

  assert {
    condition     = aws_eks_node_group.default.instance_types == tolist([local.node_instance_types[var.node_size]])
    error_message = "The nodes use the instance type of the chosen node_size."
  }

  assert {
    condition     = aws_eks_node_group.default.version == var.kubernetes_version
    error_message = "The nodes run the Kubernetes version of the control plane."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.metadata[0].name == local.cloud.storage_class
    error_message = "The default StorageClass has the name the platform components request volumes from."
  }

  assert {
    condition     = local.cloud.network_policy_enforced == var.enable_network_policies
    error_message = "NetworkPolicy objects are enforced exactly when enable_network_policies is true."
  }

  assert {
    condition     = length(aws_iam_role.external_dns) == (var.enable_external_dns ? 1 : 0)
    error_message = "The IAM role of external-dns exists exactly when enable_external_dns is true."
  }
}

run "node_size_small" {
  command = plan

  variables {
    node_size      = "small"
    node_min_count = 2
    node_max_count = 4
  }

  assert {
    condition     = aws_eks_node_group.default.instance_types == tolist(["t3.medium"])
    error_message = "small nodes are t3.medium (2 vCPU, 4 GB)."
  }

  assert {
    condition     = aws_eks_node_group.default.scaling_config[0].min_size == 2 && aws_eks_node_group.default.scaling_config[0].max_size == 4
    error_message = "node_min_count and node_max_count are the limits of the node group."
  }
}

run "node_size_medium" {
  command = plan

  variables {
    node_size = "medium"
  }

  assert {
    condition     = aws_eks_node_group.default.instance_types == tolist(["m6i.xlarge"])
    error_message = "medium nodes are m6i.xlarge (4 vCPU, 16 GB)."
  }
}

run "node_size_large" {
  command = plan

  variables {
    node_size          = "large"
    kubernetes_version = "1.37"
  }

  assert {
    condition     = aws_eks_node_group.default.instance_types == tolist(["m6i.2xlarge"])
    error_message = "large nodes are m6i.2xlarge (8 vCPU, 32 GB)."
  }

  assert {
    condition     = aws_eks_node_group.default.version == "1.37"
    error_message = "The nodes follow kubernetes_version."
  }
}

run "maximum_below_minimum_nodes" {
  command = plan

  variables {
    node_min_count = 5
    node_max_count = 3
  }

  assert {
    condition = (
      aws_eks_node_group.default.scaling_config[0].min_size == 5 &&
      aws_eks_node_group.default.scaling_config[0].desired_size == 5 &&
      aws_eks_node_group.default.scaling_config[0].max_size == 5
    )
    error_message = "A node_max_count below node_min_count gives a node group of node_min_count nodes."
  }
}

run "ingress_nginx" {
  command = plan

  variables {
    ingress_controller = "nginx"
  }

  assert {
    condition     = length(helm_release.ingress_nginx) == 1 && length(helm_release.traefik) == 0
    error_message = "nginx installs ingress-nginx and not Traefik."
  }
}

run "ingress_traefik" {
  command = plan

  variables {
    ingress_controller = "traefik"
  }

  assert {
    condition     = length(helm_release.ingress_nginx) == 0 && length(helm_release.traefik) == 1
    error_message = "traefik installs Traefik and not ingress-nginx."
  }
}

run "ingress_none" {
  command = plan

  variables {
    ingress_controller = "none"
  }

  assert {
    condition     = length(helm_release.ingress_nginx) == 0 && length(helm_release.traefik) == 0
    error_message = "none installs no ingress controller."
  }
}

run "all_components_on_in_production" {
  command = plan

  variables {
    environment                   = "production"
    enable_gitops                 = true
    enable_observability          = true
    enable_service_mesh           = true
    enable_cert_manager           = true
    enable_external_dns           = true
    ingress_controller            = "nginx"
    enable_pod_security_standards = true
    enable_network_policies       = true
    enable_opa                    = true
    enable_vault_integration      = true
  }

  assert {
    condition     = length(module.vpc.nat_gateway_ids) == 3
    error_message = "Production has one NAT gateway per availability zone."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days == 90
    error_message = "Production keeps the control plane logs for 90 days."
  }

  assert {
    condition     = jsondecode(aws_eks_addon.vpc_cni.configuration_values).enableNetworkPolicy == "true"
    error_message = "enable_network_policies switches on the network policy agent of the VPC CNI."
  }

  assert {
    condition     = local.cloud.network_policy_enforced
    error_message = "The platform components are told that NetworkPolicy objects are enforced."
  }

  assert {
    condition     = length(aws_iam_role.external_dns) == 1 && length(aws_iam_role_policy.external_dns) == 1
    error_message = "enable_external_dns creates the IAM role of external-dns."
  }

  assert {
    condition = alltrue([
      for statement in data.aws_iam_policy_document.external_dns[0].statement :
      alltrue([for action in statement.actions : startswith(action, "route53:")])
    ])
    error_message = "The role of external-dns allows Route 53 actions only."
  }

  assert {
    condition     = contains(keys(local.cloud.external_dns.service_account_annotations), "eks.amazonaws.com/role-arn")
    error_message = "The service account of external-dns is annotated with its IAM role."
  }

  assert {
    condition     = length(kubernetes_namespace_v1.platform) == 8
    error_message = "Every platform component gets its namespace."
  }
}

run "all_components_off" {
  command = plan

  variables {
    environment                   = "dev"
    enable_gitops                 = false
    enable_observability          = false
    enable_service_mesh           = false
    enable_cert_manager           = false
    enable_external_dns           = false
    ingress_controller            = "none"
    enable_pod_security_standards = false
    enable_network_policies       = false
    enable_opa                    = false
    enable_vault_integration      = false
  }

  assert {
    condition     = length(module.vpc.nat_gateway_ids) == 1
    error_message = "Environments other than production share one NAT gateway."
  }

  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days == 30
    error_message = "Environments other than production keep the control plane logs for 30 days."
  }

  assert {
    condition     = jsondecode(aws_eks_addon.vpc_cni.configuration_values).enableNetworkPolicy == "false"
    error_message = "Without enable_network_policies the network policy agent of the VPC CNI is off."
  }

  assert {
    condition     = !local.cloud.network_policy_enforced
    error_message = "The platform components are told that NetworkPolicy objects are not enforced."
  }

  assert {
    condition     = length(aws_iam_role.external_dns) == 0 && length(aws_iam_role_policy.external_dns) == 0
    error_message = "Without enable_external_dns there is no IAM role for it."
  }

  assert {
    condition     = length(local.cloud.external_dns.service_account_annotations) == 0
    error_message = "Without enable_external_dns no role is offered to its service account."
  }

  assert {
    condition     = length(kubernetes_namespace_v1.platform) == 0
    error_message = "No platform namespace is created when every component is off."
  }
}

run "external_dns_limited_to_hosted_zones" {
  command = plan

  variables {
    enable_external_dns          = true
    external_dns_hosted_zone_ids = ["Z0123456789ABCDEFGHIJ"]
  }

  assert {
    condition     = tolist(data.aws_iam_policy_document.external_dns[0].statement[0].resources) == tolist(["arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"])
    error_message = "Record changes are allowed in the listed hosted zones only."
  }

  assert {
    condition     = local.cloud.external_dns.values.extraArgs["zone-id-filter"] == tolist(["Z0123456789ABCDEFGHIJ"])
    error_message = "external-dns is told to manage the listed hosted zones only."
  }
}
