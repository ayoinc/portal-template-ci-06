output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint of the Kubernetes API"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate authority of the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "kubeconfig_command" {
  description = "Command that adds the cluster to the local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider, for IAM roles of further service accounts"
  value       = module.eks.oidc_provider_arn
}

output "node_role_arn" {
  description = "ARN of the IAM role of the nodes"
  value       = module.eks.node_group_role_arn
}

output "node_instance_type" {
  description = "EC2 instance type of the nodes"
  value       = local.node_instance_types[var.node_size]
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, used by load balancers"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, used by the nodes and pods"
  value       = module.vpc.private_subnet_ids
}

output "external_dns_role_arn" {
  description = "ARN of the IAM role of external-dns, when enable_external_dns is true"
  value       = one(aws_iam_role.external_dns[*].arn)
}

output "storage_class" {
  description = "Name of the default StorageClass"
  value       = kubernetes_storage_class_v1.gp3.metadata[0].name
}
