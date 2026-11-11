# A VPC for the cluster alone. The load balancers of the ingress controller go into the public subnets, the nodes
# and their pods into the private subnets. The vpc module tags both kinds of subnet for Kubernetes load balancers.

#trivy:ignore:AVD-AWS-0164 Public subnets hold only load balancers and NAT gateways, which need public addresses.
module "vpc" {
  source = "git::https://github.com/ayoinc/cloud-sandbox-backstage.git//catalog/terraform-modules/aws/resources/network/vpc?ref=83f9ff7222d2731d5cc0da4ab1fc1f7c46da3693"

  name        = local.name_prefix
  environment = var.environment
  vpc_cidr    = var.vpc_cidr

  # Three /24 public subnets and three /19 private subnets: every pod takes an address of a private subnet.
  public_subnet_cidrs   = [for index in range(3) : cidrsubnet(var.vpc_cidr, 8, index)]
  private_subnet_cidrs  = [for index in range(3) : cidrsubnet(var.vpc_cidr, 3, index + 1)]
  database_subnet_cidrs = []

  # Production keeps outbound traffic working when an availability zone fails; other environments share one NAT gateway.
  enable_nat_gateway = true
  single_nat_gateway = !local.is_production

  flow_logs_retention_days = local.log_retention_days
}
