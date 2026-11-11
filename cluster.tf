# -----------------------------------------------------------------------------
# Control plane
# -----------------------------------------------------------------------------

# EKS writes the control plane logs to this log group. Creating it first sets how long they are kept.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = local.log_retention_days
}

# The cluster, its IAM roles and the OIDC provider that lets service accounts assume IAM roles. Add-ons and nodes
# are declared below, in the order a new cluster needs them.
#trivy:ignore:AVD-AWS-0039 The eks module has no input for a KMS key; EKS itself encrypts all Kubernetes API data at rest from version 1.28.
#trivy:ignore:AVD-AWS-0040 The pipeline installs the platform components through the public endpoint, which requires IAM authentication.
#trivy:ignore:AVD-AWS-0041 GitHub-hosted runners have no fixed addresses; narrow cluster_endpoint_public_access_cidrs when the callers are known.
module "eks" {
  source = "git::https://github.com/ayoinc/cloud-sandbox-backstage.git//catalog/terraform-modules/aws/resources/kubernetes/eks?ref=83f9ff7222d2731d5cc0da4ab1fc1f7c46da3693"

  name            = local.name_prefix
  environment     = var.environment
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  # Nodes reach the API inside the VPC. The public endpoint stays on because the pipeline installs the platform
  # components from outside the VPC.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  cluster_addons = {}
  node_groups    = {}

  depends_on = [aws_cloudwatch_log_group.cluster]
}

# -----------------------------------------------------------------------------
# Add-ons every node needs, installed before the first node starts
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = module.eks.cluster_name
  addon_name   = "vpc-cni"

  # The network policy agent of the VPC CNI is what enforces NetworkPolicy objects.
  configuration_values = jsonencode({
    enableNetworkPolicy = tostring(var.enable_network_policies)
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = module.eks.cluster_name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# -----------------------------------------------------------------------------
# Nodes
# -----------------------------------------------------------------------------

resource "aws_eks_node_group" "default" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "${local.name_prefix}-default"
  node_role_arn   = module.eks.node_group_role_arn
  subnet_ids      = module.vpc.private_subnet_ids
  version         = var.kubernetes_version

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [local.node_instance_types[var.node_size]]
  disk_size      = var.node_disk_size_gb

  scaling_config {
    min_size     = var.node_min_count
    max_size     = local.node_max_count
    desired_size = var.node_min_count
  }

  update_config {
    max_unavailable_percentage = 33
  }

  # Between min_size and max_size the cluster autoscaler sets the number of nodes.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Nodes need the NAT gateways of the VPC to pull images, and the network add-ons to become ready.
  depends_on = [
    module.vpc,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}

# -----------------------------------------------------------------------------
# Add-ons that run as pods on the nodes
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name = module.eks.cluster_name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

# Default StorageClass: encrypted gp3 volumes, created in the zone of the pod that first uses them.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = local.storage_class_name

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

# -----------------------------------------------------------------------------
# Ready for workloads
# -----------------------------------------------------------------------------

# Exists once the cluster can schedule pods with networking, DNS and persistent volumes. Every platform component
# depends on it.
resource "terraform_data" "cluster_ready" {
  depends_on = [
    aws_eks_node_group.default,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.coredns,
    aws_eks_addon.ebs_csi,
    kubernetes_storage_class_v1.gp3,
  ]
}
