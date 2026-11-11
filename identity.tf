# IAM roles for service accounts: a pod whose service account is listed here receives a token of the cluster's
# OIDC provider and exchanges it for the credentials of its role.

data "aws_partition" "current" {}

locals {
  oidc_issuer = replace(module.eks.oidc_provider_url, "https://", "")

  # Service account ("namespace:name") that may assume each role.
  service_account_roles = merge(
    {
      ebs_csi            = "kube-system:ebs-csi-controller-sa"
      cluster_autoscaler = "kube-system:cluster-autoscaler"
    },
    var.enable_external_dns ? { external_dns = "external-dns:external-dns" } : {},
  )

  external_dns_zone_arns = length(var.external_dns_hosted_zone_ids) > 0 ? [
    for zone_id in var.external_dns_hosted_zone_ids : "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${zone_id}"
  ] : ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/*"]
}

data "aws_iam_policy_document" "service_account_trust" {
  for_each = local.service_account_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${each.value}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# -----------------------------------------------------------------------------
# EBS CSI driver: creates and attaches the volumes behind PersistentVolumeClaims
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.service_account_trust["ebs_csi"].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# -----------------------------------------------------------------------------
# Cluster autoscaler: changes the size of the node group
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid = "ReadScalingState"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ScaleNodeGroupsOfThisCluster"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${local.cluster_name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.service_account_trust["cluster_autoscaler"].json
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "cluster-autoscaler"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

# -----------------------------------------------------------------------------
# external-dns: may change records in Route 53 and nothing else
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  statement {
    sid       = "ChangeRecords"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = local.external_dns_zone_arns
  }

  statement {
    sid = "FindZonesAndRecords"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name               = "${local.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.service_account_trust["external_dns"].json
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name   = "external-dns"
  role   = aws_iam_role.external_dns[0].id
  policy = data.aws_iam_policy_document.external_dns[0].json
}
