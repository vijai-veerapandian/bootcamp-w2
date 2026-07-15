# 04 — ArgoCD & Argo Rollouts

Each installs into its **own namespace** (`argocd`, `argo-rollouts`).
Prereq: cluster up, `kubectl get nodes` Ready, AWS LB Controller installed (see `03`).

---

## A. ArgoCD (namespace: `argocd`)

```bash
# A1. Install via Helm.
#   Preferred over `kubectl apply -f .../install.yaml`, which fails on the large
#   applicationsets CRD with: "metadata.annotations: Too long: may not be more than
#   262144 bytes" (client-side apply stuffs the whole manifest into an annotation).
#   `server.insecure=true` is set here so the ALB terminates at the edge — this
#   REPLACES the manual argocd-cmd-params-cm patch (see A4).
helm repo add argo-cd https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd
helm install argocd argo-cd/argo-cd -n argocd \
  --set 'configs.params.server\.insecure=true'
kubectl -n argocd rollout status deploy/argocd-server

# A2. Initial admin password (user: admin)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```
> If you previously ran the raw-manifest install, clean it up before Helm (leftover
> CRDs lack Helm ownership labels and cause conflicts):
> `kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --ignore-not-found`
> then `kubectl delete crd applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io --ignore-not-found`.

### A3. Quick access (port-forward)
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  (accept self-signed cert)
```

### A4. Expose via ALB
ArgoCD serves its own TLS and redirects 80→443, so it runs in **insecure mode** (already set by the Helm value in A1 — no ConfigMap patch needed). Only if you installed some other way and must flip it manually:
```bash
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deploy argocd-server
```
`argocd-ingress.yaml` — host-based below for the Route 53 end-state. **For the no-DNS phase** (raw ALB URL): delete the `host:` line and set `group.name: argocd` so ArgoCD gets its **own** ALB (a hostless Ingress can't share an ALB group with another hostless app):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: monitoring     # shares the one ALB
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
spec:
  ingressClassName: alb
  rules:
    - host: argocd.vijaiveerapandian.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port: { number: 80 }
```
```bash
kubectl apply -f argocd-ingress.yaml
kubectl -n argocd get ingress -w      # wait for ADDRESS
```
Then add a Route 53 Alias A record `argocd.vijaiveerapandian.com` → ALB (see `03` §E), add ACM for HTTPS (§F). Keep `server.insecure=true` — the ALB does TLS.

---

## B. Argo Rollouts (namespace: `argo-rollouts`)

```bash
# B1. Install controller
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl -n argo-rollouts rollout status deploy/argo-rollouts

# B2. kubectl plugin (for `kubectl argo rollouts ...`)
curl -sLO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# B3. Verify
kubectl argo rollouts version
```

### B4. (Optional) Rollouts dashboard
```bash
kubectl argo rollouts dashboard        # http://localhost:3100
```

---

## Tips
- **Separation of concerns:** ArgoCD = GitOps deploy/sync; Argo Rollouts = progressive delivery (canary/blue-green). They're independent — install both, use together.
- Manage apps with `Rollout` objects instead of `Deployment` to get canary/blue-green; ArgoCD syncs them fine.
- Change the ArgoCD admin password after first login; delete `argocd-initial-admin-secret` afterward.
- Both UIs can share the one ALB via `group.name: monitoring` + distinct hosts.
- Teardown: delete Ingresses before `terraform destroy` (see `02`).
