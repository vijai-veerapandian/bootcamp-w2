# 01 — Bastion Host Key Pair

The EC2 key pair named in `terraform.tfvars` (`key_pair_name = "abcd"`) **must already exist in `us-east-1`** before `terraform apply`. Terraform does **not** create it. It is used by:

- the **bastion** EC2 instance (SSH access), and
- the **EKS managed node group** (`remote_access.ec2_ssh_key`).

> Key pairs are **regional** — it must be in `us-east-1` to match this stack, even if a key of the same name exists elsewhere.

---

## Option A — Create a new key pair (recommended)
Creates it in AWS and downloads the private key in one step.

```bash
source .env   # auth as bootcamp-user

aws ec2 create-key-pair \
  --region us-east-1 \
  --key-name abcd \
  --key-type rsa \
  --query 'KeyMaterial' \
  --output text > abcd.pem

chmod 400 abcd.pem
```

## Option B — Import an existing public key
```bash
source .env

aws ec2 import-key-pair \
  --region us-east-1 \
  --key-name abcd \
  --public-key-material fileb://~/.ssh/id_rsa.pub
```

---

## Verify
```bash
aws ec2 describe-key-pairs --region us-east-1 --key-name abcd
```
If this returns the key without error, Terraform's reference to `abcd` will resolve.

## Connect to the bastion (after deploy)
```bash
ssh -i abcd.pem ubuntu@<bastion_public_ip>     # user is 'ubuntu'
```

---

## Tips
- **Never commit the private key.** Add it to `.gitignore`:
  ```bash
  echo "*.pem" >> .gitignore
  ```
- To rename the key, change `key_pair_name` in `terraform.tfvars` to match whatever you create.
- Losing `abcd.pem` means you can't SSH to the bastion — recreate the key pair and update the instances if that happens.
