# 07 — CI/CD: App → ECR → GitOps (ArgoCD + Argo Rollouts canary)

End-to-end delivery of the `bootcamp1-app` (FastAPI backend + nginx frontend) onto EKS:
**build → ECR → GitOps → ArgoCD → canary → public HTTPS.**

## Architecture — two repos
```
bootcamp1-app  (APP repo)                      bootcamp-w2  (INFRA + GITOPS repo)  ← ArgoCD watches this
├── backend/ frontend/  (code + Dockerfiles)   ├── ecr.tf, github_oidc.tf   (ECR + CI OIDC role)
└── .github/workflows/ci.yml                    ├── helm/bootcamp1-app/      (Helm chart; frontend = Rollout)
    test → build → push image:<sha> to ECR      └── argocd/application.yaml  (ArgoCD Application)
    → bump image tag in bootcamp-w2 values.yaml
```
Flow: **push app → CI builds `image:<sha>` to ECR → CI pins `<sha>` in `bootcamp-w2` `values.yaml` →
ArgoCD (watching bootcamp-w2) syncs → Rollout canary → Promote → Healthy.**

Conventions: region `us-east-1` · account `840577818615` · cluster `vijai-cluster-1` ·
domain `aws.vijaiveerapandian.com` · GitHub owner `vijai-veerapandian`.

---

## A. ECR + GitHub OIDC (Terraform, in bootcamp-w2)
Two additive files — `terraform apply` **does not touch the cluster** (`0 to change, 0 to destroy`).

**`ecr.tf`** — two repos named `bootcamp1-app/backend` + `bootcamp1-app/frontend` (slash form; must
match the CI and Helm `values.yaml`), `scan_on_push`, `force_delete`, tag `Cluster = var.cluster_name`.

**`github_oidc.tf`** — a GitHub **OIDC provider** + an IAM **role** the CI assumes (no long-lived keys):
- trust scoped to `repo:vijai-veerapandian/bootcamp1-app:*`
- attach managed policy `AmazonEC2ContainerRegistryPowerUser`
- `output github_actions_role_arn`

```bash
source .env
terraform plan -out=tfplan     # confirm: N to add, 0 to change, 0 to destroy
terraform apply tfplan
terraform output github_actions_role_arn
```
Set that ARN as the **`AWS_ROLE_TO_ASSUME`** secret in the **bootcamp1-app** repo
(Settings → Secrets and variables → Actions).

> Gotcha: `EntityAlreadyExists` on the OIDC provider → account already has it →
> `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::840577818615:oidc-provider/token.actions.githubusercontent.com`.

---

## B. Helm chart — `helm/bootcamp1-app/` (frontend as a canary Rollout)
Simple chart: fixed names, `values.yaml`-driven, no helper templates.
```
helm/bootcamp1-app/
├── Chart.yaml
├── values.yaml            # image repos + tag (CI-managed), replicas, ingress host + cert ARN
└── templates/
    ├── backend.yaml       # Deployment + Service (Service literally named 'backend' so nginx proxy works)
    ├── frontend.yaml      # Rollout + Service   ← canary strategy
    └── ingress.yaml       # shared ALB (group.name: monitoring), host + HTTPS cert
```
Frontend `Rollout` (`apiVersion: argoproj.io/v1alpha1`) canary steps:
`setWeight 25 → pause {} (MANUAL) → setWeight 50 → pause {duration: 20s} → 100%`.

`values.yaml` image tag starts as `"bootstrap"` — a **placeholder CI overwrites with the git SHA**
(never deploy `:latest` — ArgoCD can't detect a same-tag push, and it isn't reproducible).

Render-test before committing:
```bash
helm lint helm/bootcamp1-app
helm template bootcamp1-app helm/bootcamp1-app | head -80
```
> Every `{{ .Values.X.Y }}` in a template must exist in `values.yaml`, or Helm errors with a
> "nil pointer". Find what a chart needs: `grep -rho '{{ .Values[^}]*' templates | sort -u`.

---

## C. ArgoCD Application — `argocd/application.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootcamp1-app
  namespace: argocd                 # where the Application OBJECT lives (NOT where the app runs)
spec:
  project: default
  source:
    repoURL: https://github.com/vijai-veerapandian/bootcamp-w2.git
    targetRevision: main
    path: helm/bootcamp1-app
    helm: { valueFiles: [values.yaml] }
  destination:
    server: https://kubernetes.default.svc
    namespace: bootcamp1-app        # where the APP actually runs
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true ]
```
> **Namespace vs namespace:** `metadata.namespace: argocd` = where ArgoCD keeps the instruction
> (always `argocd`). `spec.destination.namespace` = where the app lands (`bootcamp1-app`).

**ArgoCD reads from GitHub, not your laptop** — commit + push bootcamp-w2 first:
```bash
git add ecr.tf github_oidc.tf helm/ argocd/application.yaml
git commit -m "feat(app): add bootcamp1-app helm chart + argocd application"
git push
kubectl apply -f argocd/application.yaml
```
Before CI runs, pods are **`ImagePullBackOff`** (tag `:bootstrap` isn't in ECR) → app shows
**Synced + Degraded**. That's expected at this point.

---

## D. Wire the CI (retarget the GitOps handoff to bootcamp-w2)
In `bootcamp1-app/.github/workflows/ci.yml`, the `update-gitops` job:
```yaml
    env:
      GITOPS_REPO: vijai-veerapandian/bootcamp-w2      # was bootcamp1-infra
      VALUES_PATH: helm/bootcamp1-app/values.yaml       # matches bootcamp-w2 — keep
```
Add secret **`GITOPS_TOKEN`** in bootcamp1-app = a fine-grained PAT with **Contents: Read+Write on
`bootcamp-w2`** (so CI can commit the tag bump).

The `publish` job already pushes `…/bootcamp1-app/backend|frontend:<sha>` (+ `:latest`), and
`update-gitops` runs `yq` to set `.image.backend.tag` / `.image.frontend.tag = <sha>` and commits.

---

## E. Deploy & validate (the full loop)
```bash
cd ~/bootcamp1-app
git commit --allow-empty -m "ci: trigger build" && git push
```
1. **CI green** → images in ECR (`aws ecr list-images --repository-name bootcamp1-app/frontend --region us-east-1`).
2. CI commits the SHA into **bootcamp-w2** `values.yaml` → **`git pull --rebase origin main`** locally
   afterward (CI writes to the remote — your local is now behind).
3. **ArgoCD auto-syncs** → the frontend **Rollout starts a canary**, brings up ~25% new pods, then
   **PAUSES** at `pause: {}` (app shows `Progressing`).
4. **Promote** — ArgoCD UI → frontend Rollout node → **PROMOTE**, or:
   ```bash
   kubectl argo rollouts promote frontend -n bootcamp1-app
   kubectl argo rollouts get rollout frontend -n bootcamp1-app --watch
   ```
5. Canary finishes → old ReplicaSet scales to 0 → **Synced + Healthy**.

Versioning check: ECR images carry an immutable **git SHA** tag (+ `latest` as a convenience
pointer); the **deployed** tag in `values.yaml` is the **SHA** — reproducible and rollback-able.

---

## F. Route 53 + HTTPS (public URL)
HTTPS is already in the Ingress (443 listener + wildcard `*.aws.vijaiveerapandian.com` cert on the
shared ALB) — so this is just **one DNS record**.

**Route 53 → `aws.vijaiveerapandian.com` → Create record:** name `app`, type `A`, **Alias ON** →
*Alias to Application and Classic Load Balancer* → us-east-1 → the **`k8s-monitoring-…`** ALB (same
one Grafana/ArgoCD use, because the app shares `group.name: monitoring`).

```bash
dig  +short @8.8.8.8 app.aws.vijaiveerapandian.com     # ALB IPs
curl -I        https://app.aws.vijaiveerapandian.com   # 200 (frontend)
curl -I        http://app.aws.vijaiveerapandian.com    # 301 -> https
```
→ `https://app.aws.vijaiveerapandian.com` with a valid padlock.

---

## Gotchas / lessons
- **`:bootstrap` / `:latest` are not deployable tags** — the deployed tag must be the CI-pinned SHA.
- **`ImagePullBackOff` right after apply is expected** until CI pushes a real image.
- **CI writes to the remote bootcamp-w2** → `git pull --rebase` after each run or your next push is rejected (diverged).
- **A `ReplicaSet` with no `Deployment`** = a Rollout (Rollouts manage ReplicaSets); `kubectl get all` won't show the Rollout CR — use `kubectl argo rollouts get rollout ...`.
- **Namespace vs ALB `group.name`** are unrelated — the app runs in `bootcamp1-app`, the ALB is shared via the `monitoring` group label.
- **ECR repo names must match** across `ecr.tf`, `ci.yml` (`ECR_NAMESPACE`), and Helm `values.yaml` (all `bootcamp1-app/<component>`).
- **Teardown:** delete the ArgoCD Application + Ingress (removes ALB rules) before `terraform destroy`; ECR repos have `force_delete = true` so they won't block it.
