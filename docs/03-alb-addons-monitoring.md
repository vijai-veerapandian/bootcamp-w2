# 03 — ALB, Add-ons & Monitoring (on top of EKS)

Run these **after** the cluster is up and `kubectl get nodes` shows Ready nodes.
Region `us-east-1` · Cluster `vijai-cluster-1` · Account `840577818615` · Domain `vijaiveerapandian.com`

Order: **A** LB Controller (via Pod Identity) → **B** Metrics Server → **C** Prometheus + Grafana → **D** ALB Ingress → **E** Route 53 DNS → **F** HTTPS/ACM → **G** CloudFront (optional).

---

## A. AWS Load Balancer Controller — via EKS Pod Identity
Pod Identity = no OIDC trust wiring, no eksctl CloudFormation stack. All CLI/helm, no Terraform change.

```bash
source .env

# A1. Pod Identity Agent add-on
aws eks create-addon --cluster-name vijai-cluster-1 --region us-east-1 \
  --addon-name eks-pod-identity-agent
aws eks describe-addon --cluster-name vijai-cluster-1 --region us-east-1 \
  --addon-name eks-pod-identity-agent --query 'addon.status' --output text   # wait: ACTIVE

# A2. IAM policy (official, version-matched — do NOT hand-edit)
curl -o alb-controller-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.2/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://alb-controller-iam-policy.json

# A3. IAM role trusted by Pod Identity (principal: pods.eks.amazonaws.com)
cat > pod-identity-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowEksAuthToAssumeRoleForPodIdentity",
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
EOF
aws iam create-role --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file://pod-identity-trust.json
aws iam attach-role-policy --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::840577818615:policy/AWSLoadBalancerControllerIAMPolicy

# A4. Associate role → namespace/service-account
aws eks create-pod-identity-association --cluster-name vijai-cluster-1 --region us-east-1 \
  --namespace kube-system --service-account aws-load-balancer-controller \
  --role-arn arn:aws:iam::840577818615:role/AmazonEKSLoadBalancerControllerRole

# A5. Install the controller (Helm creates the SA; no role-arn annotation needed)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=vijai-cluster-1 \
  --set region=us-east-1 \
  --set vpcId=$(aws eks describe-cluster --name vijai-cluster-1 --region us-east-1 \
                 --query 'cluster.resourcesVpcConfig.vpcId' --output text) \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller

# A6. Verify
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
aws eks list-pod-identity-associations --cluster-name vijai-cluster-1 --region us-east-1
```
> If controller pods started before the association was ready:
> `kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller`

---

## B. Metrics Server
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/high-availability-1.21+.yaml
kubectl top nodes        # give it ~1 min
```
(HA variant needs ≥2 nodes — this cluster has 2.)

---

## C. Prometheus + Grafana (Helm)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
kubectl create namespace monitoring
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --set grafana.adminPassword='ChangeMe123'

# Grafana admin password (if not set above)
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

---

## D. Expose Grafana via ALB Ingress (HTTP first)
`grafana-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: monitoring     # shared ALB for many apps
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
spec:
  ingressClassName: alb
  rules:
    - host: grafana.vijaiveerapandian.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port: { number: 80 }
```
```bash
kubectl apply -f grafana-ingress.yaml
kubectl -n monitoring get ingress -w      # wait for ADDRESS (ALB DNS)

# test before DNS (host header trick):
curl -H "Host: grafana.vijaiveerapandian.com" http://<alb-dns>/api/health
```
> Reuse `group.name: monitoring` for ArgoCD/other apps so they share ONE ALB (host-based routing). Keep **Prometheus off the public ALB** — no auth by default; use `kubectl port-forward` for it.

---

## E. DNS with Route 53 (Alias to the ALB)
1. **Hosted zone** for the domain (one-time). If the domain is registered elsewhere, delegate by pointing the registrar's nameservers to the 4 Route 53 NS records.
   ```bash
   aws route53 create-hosted-zone --name vijaiveerapandian.com \
     --caller-reference $(date +%s)
   aws route53 get-hosted-zone --id <zone-id> --query 'DelegationSet.NameServers'
   ```
2. **Alias A record** → ALB (Alias is free and resolves to the ALB's changing IPs; no CNAME needed). Get the ALB's hosted-zone ID + DNS name:
   ```bash
   aws elbv2 describe-load-balancers --region us-east-1 \
     --query "LoadBalancers[?contains(LoadBalancerName,'k8s-')].[DNSName,CanonicalHostedZoneId]" --output text
   ```
   Then create an Alias A record in Route 53 (`grafana.vijaiveerapandian.com` → ALB) via console or a change-batch JSON with `AliasTarget`.
3. Access: `http://grafana.vijaiveerapandian.com`

---

## F. HTTPS with ACM (recommended)
```bash
# Public cert in us-east-1 (same region as the ALB), DNS-validated
aws acm request-certificate --region us-east-1 \
  --domain-name "*.vijaiveerapandian.com" --validation-method DNS \
  --query CertificateArn --output text
```
Add the ACM validation CNAME as a Route 53 record; wait for `ISSUED`. Then add to the Ingress annotations and re-apply:
```yaml
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:840577818615:certificate/<id>
```

---

## G. CloudFront CDN (optional, in front of the ALB)
Put CloudFront ahead of the ALB for edge caching, TLS termination, and AWS Shield:
- **Origin:** the ALB DNS name. **Viewer protocol:** redirect HTTP→HTTPS.
- **Custom domain (Alternate domain name):** `grafana.vijaiveerapandian.com` — its ACM cert **must be in `us-east-1`** (CloudFront requirement, regardless of ALB region).
- Point the Route 53 Alias A record at the **CloudFront distribution** instead of the ALB.
- Restrict the ALB to only accept CloudFront traffic (CloudFront managed prefix list on the ALB security group) so users can't bypass the CDN.
> For a dashboard like Grafana, caching benefit is small — CloudFront here is mainly for TLS at the edge + Shield/WAF. Optional for a bootcamp.

---

## Tips
- **`external-dns`** (Route 53 provider) can auto-create the Alias records from Ingress `host:` fields — worth it once you have several apps.
- **ACM cert regions:** ALB → same region as ALB (`us-east-1` here); CloudFront → always `us-east-1`.
- **One ALB, many apps:** keep `group.name` identical across Ingresses; different hosts route on the same ALB.
- **Health checks:** set `healthcheck-path` per app (Grafana `/api/health`, ArgoCD `/healthz`) — default `/` often returns a redirect and marks targets unhealthy.
- **Teardown:** delete Ingresses (ALB removal) + Pod Identity association/role/policy manually — see `02-deploy-eks-terraform.md`.
