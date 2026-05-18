#!/bin/bash
# =============================================================================
#   1. Fix DNS to 169.254.169.253 FIRST (VPC DHCP → bastion, not ready yet)
#   2. Add hostname to /etc/hosts (fixes sudo warnings)
#   3. Use IMDSv2 for instance metadata
#   4. Fetch coreos-installer from bastion (not internet)
#   5. Notify bastion when done — bastion orchestrates volume swap
# =============================================================================
set -euo pipefail
exec > /var/log/ocp-node-init.log 2>&1

echo "============================================"
echo " OCP Node Init — $(date)"
echo "============================================"

BASTION_IP="${bastion_ip}"
BOOTSTRAP_IP="${bootstrap_ip}"
ROLE="${role}"
CLUSTER_NAME="${cluster_name}"
BASE_DOMAIN="${base_domain}"
CLUSTER_DOMAIN="$CLUSTER_NAME.$BASE_DOMAIN"

# ── Fix 1: DNS before anything ────────────────────────────────────────────────
rm -f /etc/resolv.conf
echo "nameserver 169.254.169.253" > /etc/resolv.conf

# Fix 2: hostname in /etc/hosts
echo "$(hostname -I | awk '{print $1}') $(hostname)" >> /etc/hosts

# ── Fix 3: IMDSv2 ────────────────────────────────────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

NODE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/tags/instance/Name 2>/dev/null \
  || hostname | sed "s/$CLUSTER_NAME-//")

echo "==> Instance: $INSTANCE_ID  Role: $ROLE  Region: $REGION  Node: $NODE_NAME"

# ── 1. DNS and hosts ──────────────────────────────────────────────────────────
echo "$BOOTSTRAP_IP api.$CLUSTER_DOMAIN api-int.$CLUSTER_DOMAIN" >> /etc/hosts
echo "$BASTION_IP   bastion.$CLUSTER_DOMAIN" >> /etc/hosts

# ── 2. Wait for bastion ───────────────────────────────────────────────────────
echo "==> Waiting for bastion..."
until curl -sf "http://$BASTION_IP/ready" > /dev/null 2>&1; do
  echo "  $(date) — waiting..."
  sleep 15
done
echo "==> Bastion ready"

# Switch to bastion DNS
echo "nameserver $BASTION_IP" > /etc/resolv.conf
echo "nameserver 169.254.169.253" >> /etc/resolv.conf

# ── Fix 4: coreos-installer from bastion ──────────────────────────────────────
echo "==> Fetching coreos-installer from bastion"
curl -sL "http://$BASTION_IP/coreos-installer" -o /usr/local/bin/coreos-installer
chmod +x /usr/local/bin/coreos-installer
echo "==> $(/usr/local/bin/coreos-installer --version)"

# ── 3. Detect target disk ─────────────────────────────────────────────────────
echo "==> Disk layout:"
lsblk

TARGET_DISK="/dev/nvme1n1"
[ ! -b "$TARGET_DISK" ] && TARGET_DISK="/dev/xvdf"
[ ! -b "$TARGET_DISK" ] && { echo "FATAL: no secondary disk found"; exit 1; }
echo "==> Target: $TARGET_DISK"

# ── 4. Run coreos-installer ───────────────────────────────────────────────────
echo "==> Installing RHCOS for role=$ROLE"
/usr/local/bin/coreos-installer install "$TARGET_DISK" \
  --image-url     "http://$BASTION_IP/rhcos/rhcos-metal.x86_64.raw.gz" \
  --ignition-url  "http://$BASTION_IP/ignition/$ROLE.ign" \
  --insecure-ignition \
  --insecure

echo "==> Install complete — $(date)"
lsblk

# ── Fix 5: Notify bastion — it handles volume swap ────────────────────────────
echo "==> Notifying bastion of completion"
curl -sf "http://$BASTION_IP/cgi-bin/status-update.sh?$NODE_NAME" \
  || echo "WARNING: status notification failed"

echo "==> Node init complete. Bastion will now perform volume swap."
echo "==> This node will be stopped, volume swapped, and restarted into RHCOS."
