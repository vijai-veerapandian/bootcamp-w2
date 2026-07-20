# 02 — Deploy the EKS Cluster (Terraform)

Region `us-east-1` · Cluster `vijai-cluster-1` · Account `840577818615`

## Prerequisites
- **Credentials loaded:** every new terminal → `source .env` (`.env` lines use `export`).
  ```bash
  source .env
  aws sts get-caller-identity        # must show .../bootcamp-user
  ```
  `bootcamp-user` needs `AdministratorAccess` (or the scoped `eks-deploy-iam-policy.json`) with **no permissions boundary**.
- **Key pair `abcd`** exists in us-east-1 (see `01-bastion-keypair.md`).
- **Bastion AMI** in `terraform.tfvars` is still valid:
  ```bash
  aws ec2 describe-images --region us-east-1 --image-ids <ami-id> --query 'Images[0].Name' --output text
  ```

## (Optional) Capture a debug log
```bash
export TF_LOG=DEBUG
export TF_LOG_PATH=./terraform.log     # add terraform.log to .gitignore
```

## Deploy
```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan                  # ~15-20 min (control plane + node group)
```

### (Fixed) ClusterRoleBinding RBAC race
Older versions of this stack managed a `kubernetes_cluster_role_binding` via the `kubernetes`
provider, which caused two recurring failures: `apply` ending with `clusterrolebindings ...
forbidden` (access-entry propagation race → needed a second `apply`), and `destroy` failing with
`Unauthorized`. **Both are eliminated** — the bastion now gets cluster-admin **natively** via an EKS
access-policy association in `eks.tf`:
```hcl
access_entries = {
  bastion-admin = {
    principal_arn = aws_iam_role.bastion.arn
    type          = "STANDARD"
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
}
```
No kubernetes provider, no ClusterRoleBinding, no race → `apply` and `destroy` run in one shot.
Confirm access entries any time:
```bash
aws eks list-access-entries --cluster-name vijai-cluster-1 --region us-east-1
```

## Configure kubectl & verify
```bash
aws eks update-kubeconfig --region us-east-1 --name vijai-cluster-1
kubectl get nodes                       # expect 2 nodes, Ready
```

---

## Teardown

> **ORDER MATTERS.** Delete Kubernetes-managed AWS resources (Ingresses/ALBs, LoadBalancer services) **before** `terraform destroy`, or subnet/IGW deletion fails with `DependencyViolation` (the ALB's ENIs pin the subnets).

```bash
# 1. remove ALBs the LB controller created
kubectl delete ingress --all --all-namespaces
kubectl get svc -A | grep LoadBalancer          # delete any found

# 2. confirm no k8s ALBs remain
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-')].LoadBalancerName" --output text

# 3. destroy
terraform destroy -auto-approve -refresh=false
```

### Cleanups Terraform does NOT handle
- **EKS Pod Identity associations / IAM roles & policies** created via CLI (see `03-addons-ingress-dns-tls.md`) — delete manually.
- Any standalone IAM policy created with `aws iam create-policy`.

---

## Tips
- If `destroy` hangs on `aws_subnet` / `aws_internet_gateway`, an ALB is still attached — delete the Ingress, then re-run destroy.
- `-refresh=false` skips a slow/failing refresh of the EKS auth data source during destroy.
- Cost while running: NAT gateway + EKS control plane + 2× t3.medium + bastion. `terraform destroy` when done for the day.
