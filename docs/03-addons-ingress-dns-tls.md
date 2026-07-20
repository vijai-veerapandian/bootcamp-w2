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

# A2. IAM policy — apply the tracked file alb-controller-iam-policy.json (repo root).
#     It's the v2.13.0 official policy; the older v2.9.2 policy is MISSING
#     elasticloadbalancing:SetRulePriorities, which the controller needs the moment a 2nd Ingress
#     joins a shared ALB group (→ 403 AccessDenied, empty Ingress ADDRESS).
# FRESH cluster (policy does not exist yet):
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://alb-controller-iam-policy.json
# REBUILD (policy persisted → refresh it to the full content; this is the usual case):
aws iam create-policy-version \
  --policy-arn arn:aws:iam::840577818615:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://alb-controller-iam-policy.json --set-as-default
# (if it hits the 5-version limit: aws iam delete-policy-version --policy-arn <arn> --version-id <non-default vN> first)
# Running from the bastion instead of local? fetch the file there first:
#   curl -fsSL -o alb-controller-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/install/iam_policy.json

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
    - host: grafana.aws.vijaiveerapandian.com
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

Domain `vijaiveerapandian.com` is **registered at Cloudflare**. Cloudflare Registrar generally
won't let the **apex** use third-party (Route 53) nameservers, so we delegate a **subdomain**
`aws.vijaiveerapandian.com` to Route 53 and run all AWS-facing hostnames under it
(`grafana.aws.vijaiveerapandian.com`, `argocd.aws...`, etc.). An **Alias** A record is free
and points at the ALB; **use the console** — the CLI needs a hand-built change-batch JSON.

### E1. Subdomain hosted zone + delegation (one-time)
1. **Route 53 → Hosted zones → Create hosted zone**
2. **Domain name:** `aws.vijaiveerapandian.com` · **Type:** Public → **Create**
3. Open the zone → copy the **4 NS values** (the `NS` record).
4. **Cloudflare → DNS → Records** → add **4 separate `NS` records**, all named `aws`, one
   nameserver value each. Type is **NS** (not CNAME); NS records have **no proxy toggle**.
5. Verify delegation: `dig +short NS aws.vijaiveerapandian.com` → returns the 4 Route 53 NS.

> The Route 53 hosted zone **survives `terraform destroy`** (it's not in the stack) — keep it
> across rebuilds so you don't have to redo the Cloudflare NS records. Empty apex zones cost
> $0.50/mo; delete any you're not using.

### E2. Alias A record → ALB (console)
1. **Route 53 → Hosted zones →** `aws.vijaiveerapandian.com` → **Create record**
2. **Record name:** `grafana` · **Type:** `A` · **Alias:** ON
3. **Route traffic to:** *Alias to Application and Classic Load Balancer* — correct for an **ALB**
   (console groups Application + Classic; the "Network Load Balancer" entry is for NLBs only)
4. **Region:** `US East (N. Virginia)` · **Load balancer:** the `k8s-monitoring-…` ALB → **Create**

> ⚠️ **The ALB DNS name changes every time the Ingress is deleted & recreated** (and on a full
> `terraform` rebuild). A plain `kubectl apply` that *updates* an Ingress keeps the same ALB;
> a `delete` + re-apply mints a **new** ALB, leaving this Alias record pointing at a dead one.
> After any rebuild, re-point the record (re-select the ALB in the dropdown and Save).
> `external-dns` automates this — see Tips.

### E3. Verify (mind DNS caching)
```bash
dig +short @8.8.8.8 grafana.aws.vijaiveerapandian.com   # bypasses local cache → ALB IPs
curl -I http://grafana.aws.vijaiveerapandian.com        # expect 302 -> /login (Grafana)
```
> A **stale/empty `dig`** right after re-pointing is usually **negative caching** (the resolver
> cached NXDOMAIN from when the record pointed at a deleted ALB), not a misconfig. Prove it
> with `@8.8.8.8`, and flush the local cache: `sudo resolvectl flush-caches`.

### E4. Access
`http://grafana.aws.vijaiveerapandian.com`

> **Host-based Ingress must match exactly.** The Ingress `host:` **and** the DNS record name
> must both be `grafana.aws.vijaiveerapandian.com`, or the ALB returns **404** (no matching
> listener rule). If you instead see **503 "Backend service does not exist"**, the Ingress
> `backend.service.name` is wrong — it must be `<helm-release-name>-grafana` (e.g.
> `kube-prometheus-community-stack-grafana`). Check with `kubectl -n monitoring get svc`.

---

## F. HTTPS with ACM (console — detailed walkthrough)

Goal: serve `https://grafana.aws.vijaiveerapandian.com` with a browser-trusted padlock. The ALB
does the TLS termination using a free **ACM** certificate. One **wildcard** cert
`*.aws.vijaiveerapandian.com` covers `grafana.`, `argocd.`, and every future subdomain.

**Prereqs:** §E done (the `aws.vijaiveerapandian.com` Route 53 zone exists and resolves), and the
Grafana Ingress is already serving over **HTTP** (§D).

### F1. Request the certificate
1. AWS Console → search **Certificate Manager** → open **ACM**.
2. **Top-right region must read "N. Virginia" (us-east-1).** ACM is regional and the cert must
   live in the **same region as the ALB**. A cert in any other region simply won't appear when the
   LB Controller looks it up, and the Ingress annotation will fail silently. (For CloudFront later,
   us-east-1 is also the required region — so this one cert serves both.)
3. Click **Request a certificate** → choose **Request a public certificate** → **Next**.
4. **Fully qualified domain name:** type `*.aws.vijaiveerapandian.com`
   - The leading `*.` is the wildcard — it matches `grafana.aws...`, `argocd.aws...`, one level deep.
   - (Optional) **Add another name** → `aws.vijaiveerapandian.com` if you ever want the bare
     subdomain too. Not needed for `grafana.`/`argocd.`.
5. **Validation method:** select **DNS validation – recommended**.
   - DNS validation lets ACM **auto-renew forever** (as long as the validation record stays in the
     zone). Email validation does not auto-renew — avoid it.
6. **Key algorithm:** leave **RSA 2048** (default).
7. Click **Request**. You land on the certificate list; the new cert shows **Pending validation**.

### F2. Create the validation record (one click — you own the zone)
8. Click the certificate ID to open it.
9. In the **Domains** section you'll see a CNAME ACM wants created (a random
   `_abc123….aws.vijaiveerapandian.com` → `_xyz….acm-validations.aws.` value). You don't copy this
   by hand.
10. Click the **Create records in Route 53** button (top of the Domains table) → tick the domain →
    **Create records**.
    - ACM writes that CNAME straight into your `aws.vijaiveerapandian.com` hosted zone, because you
      control it. This is the whole payoff of delegating the subdomain to Route 53 in §E.
    - **Button missing / greyed out?** It only appears if ACM can find a matching hosted zone. If it
      doesn't show, confirm the `aws.vijaiveerapandian.com` zone exists and you're in the right
      account; otherwise copy the CNAME name+value and add it manually in Route 53 (type CNAME).
11. Wait for **Status → Issued**. Refresh the page every minute; DNS validation usually completes in
    **2–5 minutes** (occasionally up to ~30). It won't proceed until the CNAME resolves.
12. Copy the certificate **ARN** from the top of the cert page
    (`arn:aws:acm:us-east-1:840577818615:certificate/xxxxxxxx-…`) — needed next.

> **CLI equivalents** (if you prefer): request →
> `aws acm request-certificate --region us-east-1 --domain-name "*.aws.vijaiveerapandian.com" --validation-method DNS --query CertificateArn --output text`;
> then check status →
> `aws acm describe-certificate --region us-east-1 --certificate-arn <ARN> --query 'Certificate.Status'`.
> The console's one-click "Create records in Route 53" has no clean single-command CLI equivalent
> (you'd script the validation CNAME into a change-batch), so the console wins here.

### F3. Attach the cert to the Ingress (ALB adds an HTTPS listener)
The LB Controller reads three annotations and reconfigures the **existing** ALB — adds a `:443`
listener with the cert, and makes `:80` redirect to it. Edit `grafana-ingress.yaml`:
```yaml
    # replace the HTTP-only line with both ports:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    # force HTTP -> HTTPS:
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    # the cert from F2 (full ARN):
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:840577818615:certificate/<id>
```
Leave everything else (host, backend service name, `healthcheck-path`) unchanged. Apply:
```bash
kubectl apply -f grafana-ingress.yaml     # UPDATE in place — never delete+recreate (that changes the ALB DNS)
```
> You can omit `certificate-arn` entirely and the controller will **auto-discover** a cert whose
> domain matches the Ingress `host:` — but pinning the ARN is explicit and avoids surprises when
> multiple certs exist.

### F4. Verify
```bash
kubectl -n monitoring get ingress                       # ADDRESS must be UNCHANGED (same ALB)
curl -I https://grafana.aws.vijaiveerapandian.com       # HTTP/2 302 -> /login  (TLS works)
curl -I http://grafana.aws.vijaiveerapandian.com        # 301 -> https://       (ssl-redirect works)
```
Then browser → `https://grafana.aws.vijaiveerapandian.com` — expect a **valid padlock**, no warning.

**Troubleshooting**
- **Padlock warning / wrong cert:** the ALB has no `:443` listener yet — the annotations didn't take.
  Re-check the three annotations and `kubectl -n monitoring describe ingress grafana` events.
- **`curl` to :443 times out / connection refused:** listener not added yet; give the controller
  ~30–60s after apply, then recheck. Confirm in EC2 → Load Balancers → Listeners shows **HTTPS:443**.
- **ADDRESS changed** (rare, only if the Ingress was recreated): re-point the Route 53 Alias (E2).
- **404 over HTTPS but 200 over HTTP:** host/rule mismatch — the `:443` listener's rule must carry
  the same `host:` condition; re-apply the Ingress unchanged.

---

## G. CloudFront CDN — OPTIONAL (in front of the ALB)

> **Optional.** Grafana is already fully reachable over HTTPS via the ALB (§F). CloudFront adds an
> **edge TLS layer + AWS Shield DDoS protection + a stable domain** — for a dynamic dashboard the
> *caching* value is ~nil. Skip it if you just want the app reachable.

Prereq: §E (DNS) + §F (ACM cert **Issued**) done. The wildcard cert is reused (CloudFront requires
it in **us-east-1** — where yours is). Final path: **user → CloudFront → ALB (HTTPS) → Ingress → Grafana.**

### G1. Create distribution (the 6-step console wizard)
1. **Choose a plan:** the **Free** plan (1 TB out + 10M req/month always-free — plenty for a dashboard).
2. **Get started:**
   - **Distribution name:** anything (it's just a tag).
   - **Distribution type:** *Single website or app*.
   - **Route 53 managed domain:** `grafana.aws.vijaiveerapandian.com` — the **specific host**, NOT the
     bare `aws.vijaiveerapandian.com` (nothing serves that). Green "managed by Route 53" = it will
     auto-create the DNS record.
3. **Specify origin (Settings):**
   - **Custom origin:** the **raw ALB DNS** (`k8s-monitoring-…elb.amazonaws.com`), not the Route 53 alias.
   - **Origin settings:** *Use recommended* (HTTPS to origin).
   - **Cache settings:** *Customize* →
     - Viewer protocol policy: **Redirect HTTP to HTTPS**
     - Allowed methods: **GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE** (dashboards need writes/login)
     - **Cache policy: `CachingDisabled`** ← critical; caching breaks Grafana logins/APIs
     - **Origin request policy: `AllViewer`** ← forwards Host/cookies/auth (also makes origin TLS match)
   - **Response headers policy:** leave **None** (Grafana sends its own security headers).
4. **Enable security (WAF):** included free on this plan — enable the protections + **Rate limiting**;
   leave *monitor mode* off. (Or skip entirely — optional.)
5. **Get TLS certificate:** select the existing **`*.aws.vijaiveerapandian.com`** cert (us-east-1). Don't create a new one.
6. **Review and create** → **Create distribution.** Wait for status **Enabled / Deployed** (~5–10 min);
   note the distribution domain `dxxxx.cloudfront.net`.

### G2. DNS
Because it's a Route 53–managed domain, CloudFront **auto-points** `grafana.aws.vijaiveerapandian.com`
at the distribution. (Manual equivalent: edit the `grafana` Alias record → *Alias to CloudFront
distribution* → pick `dxxxx.cloudfront.net`.)

### G3. Lock the ALB to CloudFront only (optional hardening)
So users can't bypass the CDN by hitting the ALB directly: **EC2 → Security Groups →** the ALB's SG →
inbound `:443` → replace `0.0.0.0/0` with the managed prefix list
**`com.amazonaws.global.cloudfront.origin-facing`**.

### G4. Verify
```bash
dig  +short grafana.aws.vijaiveerapandian.com          # now resolves to CloudFront IPs
curl -I     https://grafana.aws.vijaiveerapandian.com  # Server: CloudFront ; 302 -> /login
```

### Gotchas
- **"Your account must be verified before you can add new CloudFront resources"** on *Create* — this
  is an **AWS account-level block** (new/unverified accounts), NOT a config or IAM error. Open a free
  **AWS Support → Account and billing** case, paste the exact message; ~hours to ~1 business day. The
  config is fine — re-run the same wizard once verified.
- **502 / cert error** → origin TLS name mismatch. `AllViewer` (forwarding the `grafana.` Host, which
  the wildcard cert matches) usually fixes it; else add a dedicated origin record and point the origin there.
- **Redirect loop** → origin set to HTTP while the ALB force-redirects; set origin **HTTPS only**.
- **Cost:** free-tier for this usage; no fixed/hourly fee (unlike the ALB). Your real spend is EKS/NAT/nodes/ALB.

---

## Tips
- **`external-dns`** (Route 53 provider) auto-creates/updates the Alias record from the Ingress
  `host:` — this **removes the manual re-point after every rebuild** (the #1 pain here). Add it
  once you're done iterating.
- **ALB DNS is not stable across recreate:** `kubectl apply` (update) keeps the ALB; `delete`+apply
  or a `terraform` rebuild mints a new ALB DNS → re-point the Route 53 Alias (E2).
- **Backend service name = `<helm-release-name>-grafana`** — mismatch → ALB 503 "Backend service
  does not exist" + no target group. Always `kubectl -n monitoring get svc` before writing the Ingress.
- **Negative DNS caching:** a correct record can look broken for minutes; test with `dig @8.8.8.8`
  and flush with `sudo resolvectl flush-caches`.
- **ACM cert regions:** ALB → same region as ALB (`us-east-1` here); CloudFront → always `us-east-1`.
- **One ALB, many apps:** keep `group.name` identical across Ingresses; different hosts route on the same ALB.
- **Health checks:** set `healthcheck-path` per app (Grafana `/api/health`, ArgoCD `/healthz`) — default `/` often returns a redirect and marks targets unhealthy.
- **Teardown:** delete Ingresses (ALB removal) + Pod Identity association/role/policy manually — see `02-deploy-eks-terraform.md`.
