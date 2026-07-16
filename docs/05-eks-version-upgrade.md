# 05 — EKS Cluster Version Upgrade (Production)

Golden rule: **upgrade ONE minor version at a time** (e.g. 1.32 → 1.33 → 1.34, never skip).
Upgrade order: **pre-checks → control plane → add-ons → node groups → verify.**

---

## 1. Pre-upgrade checks
```bash
# current versions
aws eks describe-cluster --name vijai-cluster-1 --region us-east-1 --query 'cluster.version'
kubectl get nodes -o wide          # node kubelet versions

# find removed/deprecated APIs before upgrading (pick one)
kubent                              # https://github.com/doitintl/kube-no-trouble
# or: pluto detect-all-in-cluster
```
- Read the target version's Kubernetes changelog for **removed APIs**; fix manifests first.
- Confirm add-on (vpc-cni, coredns, kube-proxy) versions have a build for the target version.
- Ensure **PodDisruptionBudgets** exist for critical workloads (protects them during node drain).
- Back up cluster state (e.g. **Velero**).
- **Test the upgrade in a non-prod cluster first.**

---

## 2. Upgrade the control plane
Terraform-managed stack — bump the version and apply (this changes **only** the control plane):
```bash
# terraform.tfvars
cluster_version = "1.33"

terraform plan -out=tfplan
terraform apply tfplan             # ~10 min, zero downtime for the API
```
CLI equivalent (if not using Terraform):
```bash
aws eks update-cluster-version --name vijai-cluster-1 --region us-east-1 --kubernetes-version 1.33
```
> Kubelet skew: nodes may run at most 3 minor versions below the control plane, but upgrade nodes **promptly** after the control plane — don't leave them lagging.

---

## 3. Upgrade managed add-ons
Bring core add-ons to the version matching the new control plane, one at a time:
```bash
for ADDON in vpc-cni coredns kube-proxy; do
  V=$(aws eks describe-addon-versions --addon-name $ADDON \
        --kubernetes-version 1.33 --region us-east-1 \
        --query 'addons[0].addonVersions[0].addonVersion' --output text)
  aws eks update-addon --cluster-name vijai-cluster-1 --region us-east-1 \
    --addon-name $ADDON --addon-version $V --resolve-conflicts PRESERVE
done
```
(If add-ons are managed in Terraform via the EKS module, bump their versions there and `apply` instead.)

---

## 4. Upgrade node groups
Terraform-managed: the node group follows `cluster_version` — the `apply` from step 2 (or a re-apply) triggers a **rolling** update to a new AMI. Managed node groups respect PDBs and use surge.
```bash
terraform apply                    # rolls nodes: launch new → drain old → terminate
```
CLI equivalent:
```bash
aws eks update-nodegroup-version --cluster-name vijai-cluster-1 --region us-east-1 \
  --nodegroup-name vijai-cluster-ng-1
```
Control rollout speed with the node group `update_config` (e.g. `max_unavailable_percentage`) or add surge capacity.

**Safer prod alternative — blue/green node groups:** create a new node group on the new version, cordon/drain the old one, then delete it. Gives instant rollback (just shift back) vs. an in-place roll.

---

## 5. Verify
```bash
kubectl get nodes                  # all nodes on the new version, Ready
aws eks describe-cluster --name vijai-cluster-1 --region us-east-1 --query 'cluster.version'
kubectl get pods -A | grep -v Running   # nothing stuck
```
Align the bastion's kubectl within ±1 minor of the new control plane (`bastion_bootstrap.sh.tpl`).

---

## Production checklist
- [ ] Tested in non-prod
- [ ] Deprecated APIs fixed (kubent/pluto clean)
- [ ] Add-on target versions confirmed
- [ ] PDBs in place for critical apps
- [ ] Backup taken (Velero)
- [ ] Maintenance window scheduled
- [ ] Control plane → add-ons → nodes, one minor at a time
- [ ] Post-upgrade verification passed
