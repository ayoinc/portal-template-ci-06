# orbit Kubernetes platform

Kubernetes platform for **orbit** (dev) on Amazon EKS in `eu-west-1`, managed with Terraform.

| Part       | What is created                                                                                   |
| ---------- | ------------------------------------------------------------------------------------------------- |
| Network    | VPC with three public and three private subnets, one shared NAT gateway |
| Cluster    | EKS 1.36 with the VPC CNI (network policies enforced), CoreDNS, kube-proxy and the EBS CSI driver |
| Nodes      | Managed node group of medium nodes, 3 to 10, scaled by the cluster autoscaler |
| Storage    | Default StorageClass `gp3` (encrypted EBS volumes)                                                |
| Components | Argo CD, Prometheus, Grafana and Loki, cert-manager, external-dns, traefik ingress controller, see [`docs/components.md`](docs/components.md) |

The values chosen in the portal are in [`terraform.tfvars`](terraform.tfvars). The full description is in [`docs/index.md`](docs/index.md).

## Layout

| File                                                    | Content                                                        |
| ------------------------------------------------------- | -------------------------------------------------------------- |
| `network.tf`                                            | VPC, subnets, NAT gateways                                     |
| `cluster.tf`                                            | EKS cluster, add-ons, node group, StorageClass                 |
| `identity.tf`                                           | IAM roles of the EBS CSI driver, cluster autoscaler and external-dns |
| `autoscaling.tf`                                        | Cluster autoscaler                                             |
| `platform.tf`, `platform-*.tf`, `variables-platform.tf` | Platform components installed into the cluster with Helm       |

## Pipeline

`.github/workflows/terraform.yml` runs on every push and pull request:

- `terraform fmt -check`, `terraform validate` and TFLint
- `terraform test`, which plans every node size, ingress controller and component choice against mocked providers (`tests/stack.tftest.hcl`)
- a Trivy scan of the configuration for high and critical findings

Plan and apply need access to an AWS account and stay skipped until it is configured:

| Setting             | Kind     | Purpose                                                 |
| ------------------- | -------- | ------------------------------------------------------- |
| `AWS_ROLE_ARN`      | secret   | IAM role the workflow assumes through GitHub OIDC       |
| `TF_STATE_BUCKET`   | variable | S3 bucket that holds the Terraform state                |
| `INFRACOST_API_KEY` | secret   | Optional. Enables the cost estimate on pushes to `main` |

With those set, every push to `main` produces a plan. To apply, run the workflow manually from the Actions tab with **Apply** ticked. The role in `AWS_ROLE_ARN` creates the cluster and is its administrator.

## Working locally

```bash
terraform init -backend-config="bucket=<state bucket>"
terraform plan
```

Use `terraform init -backend=false` to validate without access to the state bucket. Planning against an existing cluster needs the AWS CLI, which issues the token for the Kubernetes API.
