# orbit Kubernetes platform

Kubernetes platform for **orbit** in the **dev** environment, on Amazon EKS in region `eu-west-1`.

This page describes the cluster and its AWS resources. The components installed into the cluster are described in [Platform components](components.md).

## Architecture

```text
                         Internet
                            |
                 Network Load Balancer                public subnets
                            |
   +------------------------------------------------+
   | EKS cluster orbit-dev-eks
   |   managed node group, 3 to 10 medium nodes     private subnets, three zones
   |   VPC CNI, CoreDNS, kube-proxy, EBS CSI driver
   |   cluster autoscaler
   |   platform components
   +------------------------------------------------+
                            |
                  one shared NAT gateway              public subnets
```

## What was chosen

| Setting              | Value                                                  |
| -------------------- | ------------------------------------------------------ |
| Environment          | `dev`                            |
| Region               | `eu-west-1`                              |
| Kubernetes version   | `1.36`                      |
| Nodes                | 3 to 10 |
| Node size            | `medium` (`m6i.xlarge`, 4 vCPU, 16 GB) |
| GitOps (Argo CD)     | yes          |
| Observability stack  | yes   |
| Service mesh (Istio) | no     |
| cert-manager         | yes     |
| external-dns         | yes     |
| Ingress controller   | `traefik`                          |
| Pod Security Standards | yes |
| Network policies     | yes |
| OPA Gatekeeper       | no             |
| Vault integration    | no |

These are the contents of `terraform.tfvars`. Change a value there and open a pull request to change the platform.

## AWS resources

- **Network** (`network.tf`): a VPC `10.0.0.0/16` with three public `/24` subnets and three private `/19` subnets in three availability zones, and VPC flow logs. Nodes and pods use the private subnets and reach the internet through NAT gateways: one per availability zone in production, one shared gateway in the other environments.
- **Control plane** (`cluster.tf`): an EKS cluster with all control plane log types sent to CloudWatch Logs, kept for 90 days in production and 30 days otherwise. The API endpoint is reachable inside the VPC and, with IAM authentication, from the internet, because the pipeline installs the platform components from GitHub-hosted runners. Set `cluster_endpoint_public_access_cidrs` to limit the public endpoint to known address ranges.
- **Nodes**: one managed node group on Amazon Linux 2023 in the private subnets. `node_size` selects the instance type: `small` is `t3.medium`, `medium` is `m6i.xlarge`, `large` is `m6i.2xlarge`. The group starts with `node_min_count` nodes. A `node_max_count` below `node_min_count` is read as `node_min_count`, which gives a group of fixed size.
- **Cluster autoscaler** (`autoscaling.tf`): adds nodes when pods do not fit and removes unused nodes, between `node_min_count` and `node_max_count`. Its version follows `kubernetes_version`.
- **Add-ons**: the VPC CNI and kube-proxy are installed before the nodes start, CoreDNS and the EBS CSI driver after. With `enable_network_policies` the network policy agent of the VPC CNI is switched on, which is what makes the cluster enforce `NetworkPolicy` objects.
- **Storage**: `gp3` is the default StorageClass. It creates encrypted gp3 EBS volumes in the availability zone of the pod that first uses the claim. A volume is deleted with its PersistentVolumeClaim.
- **Load balancer**: the Service of the ingress controller is annotated so that AWS creates a Network Load Balancer in the public subnets.
- **IAM roles for service accounts** (`identity.tf`): the EBS CSI driver and the cluster autoscaler each get a role that only their service account can assume. external-dns gets a role that can change records in Route 53 and nothing else; set `external_dns_hosted_zone_ids` to limit it to chosen hosted zones.

The VPC and the cluster are built with the Terraform modules of [cloud-sandbox-backstage](https://github.com/ayoinc/cloud-sandbox-backstage/tree/main/catalog/terraform-modules/aws/resources).

## Access to the cluster

The IAM role that applies this stack (the role in `AWS_ROLE_ARN`) creates the cluster and is its administrator. To give another IAM principal access, an administrator of the AWS account switches the cluster to access entries and adds one:

```bash
aws eks update-cluster-config --region eu-west-1 --name orbit-dev-eks \
  --access-config authenticationMode=API_AND_CONFIG_MAP
aws eks create-access-entry --region eu-west-1 --cluster-name orbit-dev-eks \
  --principal-arn <role or user ARN>
aws eks associate-access-policy --region eu-west-1 --cluster-name orbit-dev-eks \
  --principal-arn <role or user ARN> --access-scope type=cluster \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
```

That principal then connects with:

```bash
aws eks update-kubeconfig --region eu-west-1 --name orbit-dev-eks
kubectl get nodes
```

## Settings that are not in the form

Set these in `terraform.tfvars` when the default does not fit.

| Variable                               | Default           | Purpose                                                        |
| -------------------------------------- | ----------------- | -------------------------------------------------------------- |
| `vpc_cidr`                             | `10.0.0.0/16`     | Address range of the VPC, a `/16`                              |
| `cluster_endpoint_public_access_cidrs` | `["0.0.0.0/0"]`   | Address ranges that may reach the public API endpoint          |
| `node_disk_size_gb`                    | `50`              | Root volume of every node                                      |
| `cluster_autoscaler_chart_version`     | `9.60.0`          | Version of the cluster-autoscaler Helm chart                   |
| `external_dns_hosted_zone_ids`         | `[]`              | Route 53 hosted zones external-dns may change; empty means all |

The settings of the platform components are listed in [Platform components](components.md).

## Pipeline

The **Terraform** workflow checks every push and pull request without needing an AWS account: formatting, `terraform validate`, `terraform test` against mocked providers (`tests/stack.tftest.hcl`), TFLint and a Trivy scan for high and critical findings.

Plan and apply are skipped until these are set in the repository settings:

| Setting             | Kind     | Purpose                                                 |
| ------------------- | -------- | ------------------------------------------------------- |
| `AWS_ROLE_ARN`      | secret   | IAM role the workflow assumes through GitHub OIDC       |
| `TF_STATE_BUCKET`   | variable | S3 bucket that holds the Terraform state                |
| `INFRACOST_API_KEY` | secret   | Optional. Enables the cost estimate on pushes to `main` |

Every push to `main` then produces a plan. To apply, run the workflow from the Actions tab with **Apply** ticked. The first apply creates the network, the cluster, the nodes and then the platform components, and takes about half an hour.

## Upgrading and removing

- **Kubernetes version**: raise `kubernetes_version` one minor version at a time. The control plane is upgraded first, then the nodes are replaced a third at a time.
- **Removing the stack**: delete the PersistentVolumeClaims and the Services of type `LoadBalancer` that were created outside this stack before `terraform destroy`; their EBS volumes and load balancers otherwise remain in the VPC and block its removal.

## Outputs

| Output                               | Description                                            |
| ------------------------------------ | ------------------------------------------------------ |
| `cluster_name`                       | Name of the EKS cluster                                |
| `cluster_endpoint`                   | Endpoint of the Kubernetes API                         |
| `cluster_certificate_authority_data` | Certificate authority of the cluster, base64 encoded   |
| `kubeconfig_command`                 | Command that adds the cluster to the local kubeconfig  |
| `oidc_provider_arn`                  | OIDC provider, for IAM roles of further service accounts |
| `node_role_arn`                      | IAM role of the nodes                                  |
| `node_instance_type`                 | EC2 instance type of the nodes                         |
| `vpc_id`                             | ID of the VPC                                          |
| `public_subnet_ids`                  | Public subnets, used by load balancers                 |
| `private_subnet_ids`                 | Private subnets, used by the nodes and pods            |
| `external_dns_role_arn`              | IAM role of external-dns, when it is enabled           |
| `storage_class`                      | Name of the default StorageClass                       |
