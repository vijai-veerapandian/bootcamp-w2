# bootcamp-w2 — EKS Runbooks

Docs for deploying and exposing an EKS cluster (`vijai-cluster-1`, `us-east-1`).
Follow them in order.

| # | Doc | What it covers |
|---|-----|----------------|
| 1 | [01-bastion-keypair.md](01-bastion-keypair.md) | Create/import the `abcd` EC2 key pair for the bastion + node group |
| 2 | [02-deploy-eks-terraform.md](02-deploy-eks-terraform.md) | Terraform deploy commands, kubeconfig, and ordered teardown |
| 3 | [03-addons-ingress-dns-tls.md](03-addons-ingress-dns-tls.md) | LB Controller (Pod Identity), Metrics Server, Prometheus/Grafana, ALB Ingress, Route 53, ACM, CloudFront |
| 4 | [04-argocd-argo-rollouts.md](04-argocd-argo-rollouts.md) | ArgoCD + Argo Rollouts, each in its own namespace, ALB exposure |
| 5 | [05-eks-version-upgrade.md](05-eks-version-upgrade.md) | Production EKS version upgrade — control plane → add-ons → nodes |
| 6 | [06-backlogs.md](06-backlogs.md) | Backlog — app deploy (HTTPS), Karpenter, KEDA; deferred Qs: external-dns, cert renewal |
| 7 | [07-ci-cd-app.md](07-ci-cd-app.md) | CI/CD: app → ECR → GitOps (ArgoCD + Argo Rollouts canary) → public HTTPS |

## Quick path
1. **Key pair** → doc 1 (must exist in us-east-1 before apply).
2. **Deploy** → doc 2 (`terraform apply` → `kubectl get nodes`).
3. **Add-ons & access** → doc 3 (run on top of the live cluster).

## Reminders
- Every new terminal: `source .env` (auth as `bootcamp-user`).
- **Teardown order:** delete Ingresses/ALBs **before** `terraform destroy` (doc 2).
- DNS/CDN uses **AWS Route 53 + CloudFront** (not Cloudflare).
