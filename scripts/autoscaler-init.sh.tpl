#!/bin/bash
# =============================================================================
#   Autoscaler VM init
#   1. Wait for bastion to be ready
#   2. Install dependencies
#   3. Copy kubeconfig + autoscaler scripts from bastion
#   4. Fill in service file placeholders
#   5. Start autoscaler webhook + watcher
# =============================================================================

set -euo pipefail
exec > /var/log/autoscaler-init.log 2>&1

echo "============================================"
echo " OCP Autoscaler Init — $(date)"
echo "============================================"

BASTION_IP="${bastion_ip}"
CLUSTER_NAME="${cluster_name}"
NODE_INSTANCE_TYPE="${node_instance_type}"
KEY_PAIR_NAME="${key_pair_name}"
RHCOS_DISK_SIZE_GB="${rhcos_disk_size_gb}"
# Removed: BASE_DOMAIN, BOOTSTRAP_IP — RHCOS workers don't need these; the
# ignition stub URL is built from BASTION_IP alone.

# ── Fix DNS first ─────────────────────────────────────────────────────────────
rm -f /etc/resolv.conf
echo "nameserver 169.254.169.253" > /etc/resolv.conf
echo "$(hostname -I | awk '{print $1}') $(hostname)" >> /etc/hosts

# ── IMDSv2 token ──────────────────────────────────────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# ── Wait for bastion ──────────────────────────────────────────────────────────
echo "==> Waiting for bastion..."
until curl -sf "http://$BASTION_IP:8080/ready" > /dev/null 2>&1; do
  echo "  $(date) — waiting..."
  sleep 15
done
echo "==> Bastion ready"

# switch to bastion DNS
echo "nameserver $BASTION_IP" > /etc/resolv.conf
echo "nameserver 169.254.169.253" >> /etc/resolv.conf

# ── Install dependencies ──────────────────────────────────────────────────────
echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  python3 python3-pip \
  curl wget \
  awscli \
  openssh-client \
  unzip

# ── Install oc CLI ────────────────────────────────────────────────────────────
echo "==> Installing oc CLI"
wget -q "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" \
  -O /tmp/oc.tar.gz
tar -xzf /tmp/oc.tar.gz -C /tmp
mv /tmp/oc /tmp/kubectl /usr/local/bin/

# ── Setup autoscaler directory ────────────────────────────────────────────────
echo "==> Setting up autoscaler"
mkdir -p /opt/autoscaler/scripts
mkdir -p /home/ubuntu/.ssh
chown ubuntu:ubuntu /opt/autoscaler

# ── Wait for cluster to be ready then copy kubeconfig ─────────────────────────
echo "==> Waiting for kubeconfig to be available..."
until curl -sf "http://$BASTION_IP:8080/auth/kubeconfig" > /dev/null 2>&1; do
  echo "  $(date) — waiting for cluster install to complete..."
  sleep 60
done

curl -s "http://$BASTION_IP:8080/auth/kubeconfig" -o /opt/autoscaler/kubeconfig
cp /opt/autoscaler/kubeconfig /home/ubuntu/kubeconfig
chown ubuntu:ubuntu /home/ubuntu/kubeconfig
echo "export KUBECONFIG=/opt/autoscaler/kubeconfig" >> /home/ubuntu/.bashrc

# ── Fetch autoscaler scripts from bastion ─────────────────────────────────────
echo "==> Fetching autoscaler scripts"
curl -sf "http://$BASTION_IP:8080/autoscaler/webhook.py"        -o /opt/autoscaler/webhook.py
curl -sf "http://$BASTION_IP:8080/autoscaler/watcher.py"        -o /opt/autoscaler/watcher.py
curl -sf "http://$BASTION_IP:8080/autoscaler/requirements.txt"  -o /opt/autoscaler/requirements.txt
curl -sf "http://$BASTION_IP:8080/autoscaler/storage-watcher.py" -o /opt/autoscaler/storage-watcher.py

# ── Fetch ignition stub template ──────────────────────────────────────────────
# CHANGED: was node-init.sh.tpl (Ubuntu cloud-init for the volume-swap flow);
# now the ignition stub used by webhook.py for RHCOS-direct-boot workers.
echo "==> Fetching ignition stub template"
curl -sf "http://$BASTION_IP:8080/scripts/ignition-stub.json.tpl" \
  -o /opt/autoscaler/scripts/ignition-stub.json.tpl

# ── Install python deps ───────────────────────────────────────────────────────
pip3 install -r /opt/autoscaler/requirements.txt

# ── Fetch and configure systemd service ───────────────────────────────────────
echo "==> Configuring autoscaler service"
curl -sf "http://$BASTION_IP:8080/autoscaler/ocp-autoscaler.service" \
  -o /etc/systemd/system/ocp-autoscaler.service

# ── Resolve dynamic AWS values ────────────────────────────────────────────────
# CHANGED: was Ubuntu AMI (owner 099720109477); now resolves RHCOS AMI for
# direct-boot workers (owner 531415883065 — Red Hat).
RHCOS_AMI=$(aws ec2 describe-images \
  --owners 531415883065 \
  --filters "Name=name,Values=rhcos-414.92*" \
            "Name=architecture,Values=x86_64" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --region $REGION --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=$CLUSTER_NAME-subnet" \
  --query 'Subnets[0].SubnetId' \
  --region $REGION --output text)

NODE_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=$CLUSTER_NAME-nodes-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --region $REGION --output text)

IAM_PROFILE="$CLUSTER_NAME-node-profile"

# Fail loudly if any required value couldn't be resolved
for v in RHCOS_AMI SUBNET_ID NODE_SG_ID; do
  if [ -z "$${!v}" ] || [ "$${!v}" = "None" ]; then
    echo "FATAL: $v is empty — check AWS tags / RHCOS AMI availability in $REGION"
    exit 1
  fi
done

echo "==> Resolved:"
echo "    RHCOS_AMI          = $RHCOS_AMI"
echo "    SUBNET_ID          = $SUBNET_ID"
echo "    NODE_SG_ID         = $NODE_SG_ID"
echo "    IAM_PROFILE        = $IAM_PROFILE"
echo "    NODE_INSTANCE_TYPE = $NODE_INSTANCE_TYPE"
echo "    KEY_PAIR_NAME      = $KEY_PAIR_NAME"
echo "    RHCOS_DISK_SIZE_GB = $RHCOS_DISK_SIZE_GB"
echo "    REGION             = $REGION"
echo "    AZ                 = $AZ"

# ── Fill in placeholders in service file ──────────────────────────────────────
# CHANGED: removed __BASE_DOMAIN__, __BOOTSTRAP_IP__, __UBUNTU_AMI__.
# ADDED:   __RHCOS_AMI__, __KEY_PAIR_NAME__, __RHCOS_DISK_SIZE_GB__,
#          __NODE_INSTANCE_TYPE__ (was hardcoded m5.metal in the old unit).
sed -i \
  -e "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" \
  -e "s|__BASTION_IP__|$BASTION_IP|g" \
  -e "s|__RHCOS_AMI__|$RHCOS_AMI|g" \
  -e "s|__KEY_PAIR_NAME__|$KEY_PAIR_NAME|g" \
  -e "s|__RHCOS_DISK_SIZE_GB__|$RHCOS_DISK_SIZE_GB|g" \
  -e "s|__NODE_INSTANCE_TYPE__|$NODE_INSTANCE_TYPE|g" \
  -e "s|__SUBNET_ID__|$SUBNET_ID|g" \
  -e "s|__NODE_SG_ID__|$NODE_SG_ID|g" \
  -e "s|__IAM_PROFILE__|$IAM_PROFILE|g" \
  -e "s|__REGION__|$REGION|g" \
  -e "s|__AZ__|$AZ|g" \
  /etc/systemd/system/ocp-autoscaler.service

# Defensive check: no unresolved placeholders left
if grep -E '__[A-Z_]+__' /etc/systemd/system/ocp-autoscaler.service; then
  echo "FATAL: unresolved placeholders above — service will fail to start"
  exit 1
fi

# ── Start autoscaler ──────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable ocp-autoscaler
systemctl start ocp-autoscaler

echo "==> Autoscaler running"
echo "============================================"
echo " AUTOSCALER READY — $(date)"
echo "============================================"