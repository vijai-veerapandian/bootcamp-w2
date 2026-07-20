# Post idea — Shared vs. per-tenant ALB on EKS

Draft LinkedIn post based on a real lesson from wiring up ALB Ingress on an EKS bootcamp cluster.

---

## Draft post

**One ALB for all your apps, or one per app? On EKS, this choice quietly decides your blast radius.**

I was exposing Grafana and ArgoCD on an EKS cluster through the AWS Load Balancer Controller. One annotation — `group.name` — decides whether Ingresses **share a single ALB** or each get **their own**. Looks trivial. It isn't.

Then it bit me: a missing IAM permission (`elasticloadbalancing:SetRulePriorities`) failed the reconcile for the **entire shared ALB group**. My first app was fine — the moment a *second* app joined the same ALB, neither could get an address. That's shared-ALB blast radius in one screenshot.

Here's the trade-off I wish I'd internalized earlier:

**Shared ALB (one for many apps)**
✅ Cheaper — one load balancer, not N
✅ Fewer IPs consumed in your subnets (this becomes a real limit at scale)
✅ One place for logs, WAF, TLS
❌ One bad Ingress can break reconciliation for every app on it
❌ Weak isolation — shared SG, WAF, rate limits across tenants
❌ Listener-rule quotas and noisy-neighbor effects

**ALB per app/tenant**
✅ Strong fault + security + performance isolation
✅ Per-tenant WAF, security groups, certs, access logs
✅ Independent lifecycle — recreate one without touching others
❌ Cost scales with tenant count
❌ Each ALB pins IPs in every AZ subnet — hundreds can drain a /24
❌ More DNS records, certs, and alarms to manage

**The deciding factor isn't cost — it's the trust boundary.**
Trusted internal tools (my Grafana + ArgoCD)? Share an ALB. External or compliance-separated tenants? Give them their own — and remember the ALB is just the edge: real multi-tenancy also needs namespaces, NetworkPolicies, RBAC, and quotas.

The pattern most teams land on: not all-shared, not all-isolated, but **grouped by team / environment / trust tier.** Cap the blast radius without an ALB explosion.

Small annotation. Big architectural consequence.

#Kubernetes #EKS #AWS #DevOps #PlatformEngineering #CloudArchitecture

---

## Notes for editing before posting
- Add a screenshot of the `SetRulePriorities` error or the two Ingresses sharing a `group.name` — visuals lift reach.
- Optional shorter hook: *"A one-line Kubernetes annotation decided my production blast radius. Here's what I learned."*
- Keep it first-person and specific — the real failure story is what makes it credible.
- Consider a follow-up post on the *rest* of multi-tenant isolation (NetworkPolicies, RBAC, quotas, per-tenant node groups).
