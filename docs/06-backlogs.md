# 06 — Open Items & Deferred Questions

Running backlog for the bootcamp-w2 EKS project — things to build next, and questions to
work through. Newest work items on top; the two deferred **discussion** questions are last.

---

## Work items (planned)

### 1. Deploy an application on the cluster, accessible via HTTPS
- Deploy a real app (Deployment + Service) into its own namespace.
- Expose it through the **shared ALB** (`group.name: monitoring`), host-based
  (`app.aws.vijaiveerapandian.com`), backend `Service:port`.
- HTTPS via the existing **wildcard ACM cert** (`*.aws.vijaiveerapandian.com`) — same 3
  annotations as Grafana/ArgoCD (`listen-ports [80,443]`, `ssl-redirect`, `certificate-arn`).
- Route 53 Alias A record → the `k8s-monitoring-…` ALB (or auto via external-dns once added).
- Pattern reference: `03-addons-ingress-dns-tls.md` §D–F.

### 2. Karpenter (node autoscaling)
- Replace/augment the managed node group's static scaling with **Karpenter** for fast,
  right-sized, just-in-time node provisioning.
- Needs: Karpenter controller (Helm), an IAM role (via **Pod Identity**, same pattern as the LB
  controller), a `NodePool` + `EC2NodeClass`, and SQS/interruption handling.
- Open sub-question: keep the EKS managed node group as a small baseline and let Karpenter handle
  burst, or go Karpenter-only?

### 3. KEDA (event-driven pod autoscaling)
- Add **KEDA** for scaling workloads on external signals (queue depth, Prometheus metrics, cron,
  etc.) beyond CPU/memory HPA.
- Needs: KEDA operator (Helm), `ScaledObject`/`ScaledJob` per workload.
- Natural demo: scale a consumer app off a Prometheus metric (Prometheus is already installed).

> More items to be added — deploying apps, autoscaling, and others discussed will land here first,
> then graduate into their own numbered runbook once done.

---

## Deferred questions (discuss last)

### Q1. external-dns + automatic Route 53 records
- **Why:** today the Route 53 Alias record must be **re-pointed by hand every rebuild** (the ALB
  DNS name changes on Ingress recreate / `terraform` rebuild — the #1 recurring pain).
- **What to cover:** install external-dns (Helm) with the **Route 53 provider**, scoped to the
  `aws.vijaiveerapandian.com` zone; IAM via **Pod Identity**; how it reads the Ingress `host:` and
  auto-creates/updates/deletes the Alias records; `txt-owner-id` and policy (`sync` vs `upsert-only`).

### Q2. SSL/TLS certificate renewal process
- **Why:** understand what keeps `https://…aws.vijaiveerapandian.com` valid long-term.
- **What to cover:** how **ACM auto-renews** DNS-validated public certs (the validation CNAME must
  stay in Route 53); what to verify (cert status, `RenewalEligibility`, expiry); why email
  validation does NOT auto-renew; and where CloudFront/ALB pick up the renewed cert automatically
  (same ARN, no redeploy).
