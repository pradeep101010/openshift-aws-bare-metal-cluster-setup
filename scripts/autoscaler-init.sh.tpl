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
BASE_DOMAIN="${base_domain}"
BOOTSTRAP_IP="${bootstrap_ip}"
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
until curl -sf "http://$BASTION_IP/ready" > /dev/null 2>&1; do
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

# ── Wait for cluster to be ready then copy kubeconfig ────────────────────────
echo "==> Waiting for kubeconfig to be available..."
until curl -sf "http://$BASTION_IP/auth/kubeconfig" > /dev/null 2>&1; do
  echo "  $(date) — waiting for cluster install to complete..."
  sleep 60
done

curl -s "http://$BASTION_IP/auth/kubeconfig" -o /opt/autoscaler/kubeconfig
cp /opt/autoscaler/kubeconfig /home/ubuntu/kubeconfig
chown ubuntu:ubuntu /home/ubuntu/kubeconfig
echo "export KUBECONFIG=/opt/autoscaler/kubeconfig" >> /home/ubuntu/.bashrc

# ── Fetch autoscaler scripts from bastion ────────────────────────────────────
echo "==> Fetching autoscaler scripts"
curl -sf "http://$BASTION_IP/autoscaler/webhook.py"              -o /opt/autoscaler/webhook.py
curl -sf "http://$BASTION_IP/autoscaler/watcher.py"              -o /opt/autoscaler/watcher.py
curl -sf "http://$BASTION_IP/autoscaler/requirements.txt"        -o /opt/autoscaler/requirements.txt

# ── Fetch node-init script (used by webhook to generate userdata) ─────────────
echo "==> Fetching node-init script"
curl -sf "http://$BASTION_IP/scripts/node-init.sh.tpl" \
  -o /opt/autoscaler/scripts/node-init.sh.tpl

# ── Install python deps ───────────────────────────────────────────────────────
pip3 install -r /opt/autoscaler/requirements.txt --break-system-packages

# ── Fetch and configure systemd service ──────────────────────────────────────
echo "==> Configuring autoscaler service"
curl -sf "http://$BASTION_IP/autoscaler/ocp-autoscaler.service" \
  -o /etc/systemd/system/ocp-autoscaler.service

# resolve dynamic AWS values
UBUNTU_AMI=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
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

echo "==> Resolved: AMI=$UBUNTU_AMI SUBNET=$SUBNET_ID SG=$NODE_SG_ID"

# fill in placeholders in service file
sed -i "s|__CLUSTER_NAME__|$CLUSTER_NAME|g"   /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__BASTION_IP__|$BASTION_IP|g"       /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__BOOTSTRAP_IP__|$BOOTSTRAP_IP|g"     /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__BASE_DOMAIN__|$BASE_DOMAIN|g"     /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__UBUNTU_AMI__|$UBUNTU_AMI|g"       /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__SUBNET_ID__|$SUBNET_ID|g"         /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__NODE_SG_ID__|$NODE_SG_ID|g"       /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__IAM_PROFILE__|$IAM_PROFILE|g"     /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__REGION__|$REGION|g"               /etc/systemd/system/ocp-autoscaler.service
sed -i "s|__AZ__|$AZ|g"                       /etc/systemd/system/ocp-autoscaler.service

# ── Start autoscaler ──────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable ocp-autoscaler
systemctl start ocp-autoscaler

echo "==> Autoscaler running"
echo "============================================"
echo " AUTOSCALER READY — $(date)"
echo "============================================"