# Values chosen when this repository was created are in terraform.tfvars.
# The variables of the platform components are in variables-platform.tf.

variable "project_name" {
  description = "Name of the project, used as a prefix for resource names"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.project_name)) && length(var.project_name) <= 16
    error_message = "project_name must be at most 16 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Environment this stack belongs to"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be dev, staging or production."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
}

# --- Network ------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block of the VPC, a /16. Pods get their addresses from its private subnets."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a /16 IPv4 CIDR block."
  }
}

# --- Cluster ------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane and the nodes, for example 1.36"
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as 1.36."
  }
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks that may reach the public endpoint of the Kubernetes API. Requests still need IAM authentication."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- Nodes --------------------------------------------------------------------

variable "node_min_count" {
  description = "Smallest number of nodes, also the number the node group starts with"
  type        = number

  validation {
    condition     = var.node_min_count >= 1 && floor(var.node_min_count) == var.node_min_count
    error_message = "node_min_count must be a whole number of at least 1."
  }
}

variable "node_max_count" {
  description = "Largest number of nodes the cluster autoscaler may scale the node group to. A value below node_min_count counts as node_min_count."
  type        = number

  validation {
    condition     = var.node_max_count >= 1 && floor(var.node_max_count) == var.node_max_count
    error_message = "node_max_count must be a whole number of at least 1."
  }
}

variable "node_size" {
  description = "Size of the nodes: small (2 vCPU, 4 GB), medium (4 vCPU, 16 GB) or large (8 vCPU, 32 GB)"
  type        = string

  validation {
    condition     = contains(["small", "medium", "large"], var.node_size)
    error_message = "node_size must be small, medium or large."
  }
}

variable "node_disk_size_gb" {
  description = "Size of the root volume of every node in GB"
  type        = number
  default     = 50
}

variable "cluster_autoscaler_chart_version" {
  description = "Version of the cluster-autoscaler Helm chart"
  type        = string
  default     = "9.60.0"
}

# --- DNS ----------------------------------------------------------------------

variable "external_dns_hosted_zone_ids" {
  description = "IDs of the Route 53 hosted zones external-dns may change. Empty: every hosted zone of the account."
  type        = list(string)
  default     = []
}
