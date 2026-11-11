locals {
  name_prefix   = "${var.project_name}-${var.environment}"
  is_production = var.environment == "production"

  # The eks module names the cluster "<name>-eks".
  cluster_name = "${local.name_prefix}-eks"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Instance type behind each node size of the form: 2 vCPU / 4 GB, 4 vCPU / 16 GB, 8 vCPU / 32 GB.
  node_instance_types = {
    small  = "t3.medium"
    medium = "m6i.xlarge"
    large  = "m6i.2xlarge"
  }

  # A maximum below the minimum is read as a node group of fixed size.
  node_max_count = max(var.node_min_count, var.node_max_count)

  storage_class_name = "gp3"

  # Days the VPC flow logs and the control plane logs are kept.
  log_retention_days = local.is_production ? 90 : 30

  # What the platform components in platform*.tf need to know about this cloud.
  cloud = {
    name         = "aws"
    cluster_name = module.eks.cluster_name

    # The VPC CNI enforces NetworkPolicy objects when its network policy agent is switched on (cluster.tf).
    network_policy_enforced = var.enable_network_policies

    external_dns = {
      provider = "aws"
      service_account_annotations = var.enable_external_dns ? {
        "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns[0].arn
      } : {}
      values = {
        env = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
        # Limits external-dns to the hosted zones its role may change.
        extraArgs = length(var.external_dns_hosted_zone_ids) > 0 ? {
          zone-id-filter = var.external_dns_hosted_zone_ids
        } : {}
      }
    }

    # A Network Load Balancer in the public subnets, spreading connections over the nodes of all zones.
    ingress_service_annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"                              = "nlb"
      "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
    }

    storage_class = local.storage_class_name
  }
}
