#!/bin/bash
# ───────────────────────────────────────────────
# Bastion Bootstrap Script
# Automates everything from the original manual STEP-1 and STEP-2:
#   - apt update + unzip
#   - AWS CLI v2 installation
#   - kubectl installation (v1.35.0 to match your original script)
#   - eksctl installation
# Runs automatically on first boot via EC2 user_data — no manual SSH needed.
# ───────────────────────────────────────────────
set -euo pipefail

LOGFILE="/var/log/bastion-bootstrap.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "==== Bastion bootstrap started at $(date) ===="

# STEP 1: System update
apt-get update -y
apt-get install -y unzip curl wget tar git jq

# STEP 2a: AWS CLI v2 installation
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -o awscliv2.zip
./aws/install
aws --version

# STEP 2b: kubectl installation (v1.32.x to match the EKS control plane version)
curl -fLO "https://dl.k8s.io/release/v1.32.3/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/kubectl
kubectl version --client

# STEP 2c: eksctl installation
curl -L "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" -o eksctl.tar.gz
tar -xzvf eksctl.tar.gz -C /tmp
mv /tmp/eksctl /usr/local/bin/eksctl
eksctl version

# STEP 2d: helm installation (useful for installing add-ons post-cluster-creation)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Configure kubectl to talk to the cluster created by Terraform automatically
# When the instance boots, write kubeconfig for ubuntu and verify cluster access.
mkdir -p /home/ubuntu/.kube /root/.kube
chown -R ubuntu:ubuntu /home/ubuntu/.kube

export HOME=/home/ubuntu
export AWS_DEFAULT_REGION="${aws_region}"

retry_count=0
until aws eks describe-cluster --region "${aws_region}" --name "${cluster_name}" --query "cluster.status" --output text | grep -q "ACTIVE"; do
  retry_count=$((retry_count + 1))
  if [ "$retry_count" -ge 40 ]; then
    echo "Cluster ${cluster_name} is not ACTIVE after $((retry_count * 15)) seconds. Exiting."
    exit 1
  fi
  echo "Waiting for EKS cluster ${cluster_name} to become ACTIVE... (attempt $retry_count)"
  sleep 15
done

sudo -u ubuntu bash -lc "HOME=/home/ubuntu AWS_DEFAULT_REGION=${aws_region} aws eks update-kubeconfig --region ${aws_region} --name ${cluster_name}"
cp /home/ubuntu/.kube/config /root/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config
chmod 600 /home/ubuntu/.kube/config /root/.kube/config

cat > /etc/profile.d/eks-kubeconfig.sh <<EOF
export AWS_REGION=${aws_region}
export KUBECONFIG=/home/ubuntu/.kube/config
alias k='kubectl'
EOF

cat > /home/ubuntu/.profile <<EOF
export AWS_REGION=${aws_region}
export KUBECONFIG=/home/ubuntu/.kube/config
alias k='kubectl'
EOF

cat > /root/.profile <<EOF
export AWS_REGION=${aws_region}
export KUBECONFIG=/root/.kube/config
alias k='kubectl'
EOF

chown ubuntu:ubuntu /home/ubuntu/.profile

echo "==== Bastion bootstrap completed at $(date) ===="
echo "kubectl config path: /home/ubuntu/.kube/config"
echo "Run: kubectl get nodes"
