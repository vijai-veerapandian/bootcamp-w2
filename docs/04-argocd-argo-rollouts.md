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
`argocd-ingress.yaml` — host-based below (host `argocd.aws.vijaiveerapandian.com`, matching the
`aws.` delegated subdomain from `03 §E`).

> **Namespace vs. ALB group — don't confuse them.** ArgoCD lives entirely in the **`argocd`
> namespace** (metadata below). The `alb.ingress.kubernetes.io/group.name` annotation is **not a
> namespace** — it's just a label telling the LB Controller which physical ALB to use. It's set to
> **`monitoring`** to match Grafana's Ingress (`03 §D`), so **this project runs a single shared
> ALB**: ArgoCD rides the same ALB as Grafana, and host-based routing (`grafana.` vs `argocd.`)
> keeps the two apps separate on it. The group is named `monitoring` only because Grafana claimed
> the ALB first — treat it as a generic "shared-ALB" label, not monitoring-specific.
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: monitoring     # SHARED single ALB with Grafana (an ALB group label, NOT a namespace)
    # HTTPS baked in — same wildcard cert as Grafana (*.aws.vijaiveerapandian.com covers argocd.):
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:840577818615:certificate/<id>
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
spec:
  ingressClassName: alb
  rules:
    - host: argocd.aws.vijaiveerapandian.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80              # backend stays 80 — ArgoCD is insecure; ALB terminates TLS
```
```bash
kubectl apply -f argocd-ingress.yaml       # apply (UPDATE) — never delete+recreate; that changes the ALB DNS
kubectl -n argocd get ingress -w           # wait for ADDRESS
```
Then add a Route 53 Alias A record `argocd` in the **`aws.vijaiveerapandian.com`** zone → the ALB
(console steps in `03 §E2`). Because `group.name: monitoring` puts ArgoCD on the **same single ALB
as Grafana**, select the **same `k8s-monitoring-…`** load balancer Grafana uses — both `grafana.`
and `argocd.` resolve to that one ALB. The wildcard cert from `03 §F` already covers `argocd.`, so
no new cert is needed. Keep `server.insecure=true` — the ALB does TLS, backend stays HTTP:80.

**Start HTTP-only?** Drop the `ssl-redirect` + `certificate-arn` lines and use
`listen-ports: '[{"HTTP":80}]'`; add the three HTTPS lines back once the HTTP URL works (mirrors
`03 §D → §F`).

Verify:
```bash
curl -I https://argocd.aws.vijaiveerapandian.com     # 200/307 to the ArgoCD login UI
curl -I http://argocd.aws.vijaiveerapandian.com      # 301 -> https (ssl-redirect)
```

> **Gotchas (same as Grafana, see `03 §E`):** the ALB DNS changes on any delete+recreate/rebuild →
> re-point the Alias. **404** = Ingress `host:` ≠ DNS record name. **503 "Backend service does not
> exist"** = wrong `backend.service.name` (the ArgoCD server service is `argocd-server` for the Helm
> release named `argocd`; confirm with `kubectl -n argocd get svc`).

---

## B. Argo Rollouts (namespace: `argo-rollouts`)

> **No DNS / no HTTPS / no ALB for Rollouts.** Argo Rollouts is a **controller** (it manages
> `Rollout` objects for canary/blue-green), not a web app — there's nothing to expose publicly.
> Its dashboard is **local only** (B4, `localhost:3100`). So no Alias A record and no `:443` here.

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

## C. CloudFront CDN for ArgoCD — OPTIONAL

> **Optional.** ArgoCD is already reachable over HTTPS via the ALB (§A4). CloudFront only adds edge
> TLS + Shield + a stable domain; skip if you just want it reachable.

Same wizard and settings as Grafana — see **`03 §G`** for the full 6-step walkthrough. Only the
host and health check differ:
- **Route 53 managed domain / Domains to serve:** `argocd.aws.vijaiveerapandian.com`
- **Custom origin:** the same **`k8s-monitoring-…` ALB DNS** (ArgoCD shares that ALB).
- **Cache policy `CachingDisabled`**, **Origin request policy `AllViewer`**, **Redirect HTTP→HTTPS**,
  reuse the **`*.aws.vijaiveerapandian.com`** cert (us-east-1).

**ArgoCD-specific notes:**
- Keep `server.insecure=true` (§A1) — the ALB/CloudFront terminate TLS; backend stays HTTP:80.
- The **UI** works fine behind CloudFront. The **`argocd` CLI** uses gRPC — if it misbehaves through
  the CDN, log in with `argocd login argocd.aws.vijaiveerapandian.com --grpc-web`.
- Same **account-verification** gotcha applies (see `03 §G` Gotchas) — a new/unverified account must
  be verified by AWS Support before any CloudFront distribution can be created.

Verify:
```bash
dig  +short argocd.aws.vijaiveerapandian.com
curl -I     https://argocd.aws.vijaiveerapandian.com   # Server: CloudFront ; 200/307 -> ArgoCD login
```

---

## Tips
- **Separation of concerns:** ArgoCD = GitOps deploy/sync; Argo Rollouts = progressive delivery (canary/blue-green). They're independent — install both, use together.
- Manage apps with `Rollout` objects instead of `Deployment` to get canary/blue-green; ArgoCD syncs them fine.
- Change the ArgoCD admin password after first login; delete `argocd-initial-admin-secret` afterward.
- Both UIs can share the one ALB via `group.name: monitoring` + distinct hosts.
- Teardown: delete Ingresses before `terraform destroy` (see `02`).
