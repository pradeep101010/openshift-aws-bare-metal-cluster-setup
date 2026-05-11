#!/bin/bash
# =============================================================================
# complete-setup.sh
# Run this AFTER terraform apply completes.
# Monitors all nodes for coreos-installer completion, then waits for RHCOS
# to boot and OCP bootstrap to finish.
#
# Usage: ./complete-setup.sh <bastion_public_ip> <aws_region> <cluster_name>
# =============================================================================
set -euo pipefail

BASTION_IP="${1:?Usage: $0 <bastion_public_ip> <aws_region> <cluster_name>}"
AWS_REGION="${2:?Usage: $0 <bastion_public_ip> <aws_region> <cluster_name>}"
CLUSTER_NAME="${3:?Usage: $0 <bastion_public_ip> <aws_region> <cluster_name>}"
SSH_KEY="${4:-~/.ssh/id_rsa}"

NODES="bootstrap master0 master1 master2 worker0 worker1"

echo "============================================"
echo " OCP Complete Setup"
echo " Bastion:  $BASTION_IP"
echo " Region:   $AWS_REGION"
echo " Cluster:  $CLUSTER_NAME"
echo "============================================"

# ── Helper: SSH to bastion ────────────────────────────────────────────────────
bastion_ssh() {
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ubuntu@"$BASTION_IP" "$@"
}

# ── 1. Wait for bastion to finish setup ───────────────────────────────────────
echo ""
echo "==> [1/5] Waiting for bastion to finish setup..."
until curl -sf "http://$BASTION_IP/ready" > /dev/null 2>&1; do
  echo "  $(date) — bastion not ready yet, waiting..."
  sleep 20
done
echo "  Bastion is ready!"

# ── 2. Tail bastion init log ──────────────────────────────────────────────────
echo ""
echo "==> [2/5] Bastion init log (last 20 lines):"
bastion_ssh "tail -20 /var/log/bastion-init.log" || true

# ── 3. Monitor nodes for coreos-installer completion ─────────────────────────
echo ""
echo "==> [3/5] Waiting for all nodes to complete coreos-installer..."
echo "    (Each node downloads ~1 GB RHCOS image — allow 10-15 min)"

while true; do
  ALL_DONE=true
  echo ""
  echo "  Status at $(date):"
  for NODE in $NODES; do
    STATUS=$(curl -sf "http://$BASTION_IP/status/$NODE" 2>/dev/null || echo "pending")
    echo "    $NODE: $STATUS"
    [ "$STATUS" != "done" ] && ALL_DONE=false
  done
  $ALL_DONE && break
  sleep 30
done
echo "  All nodes completed coreos-installer!"

# ── 4. Wait for nodes to swap volumes and boot RHCOS ─────────────────────────
echo ""
echo "==> [4/5] Waiting for nodes to swap volumes and boot RHCOS..."
echo "    (Volume swap + first RHCOS boot takes ~5-10 min per node)"

BASE_DOMAIN=$(bastion_ssh "grep base_domain /home/ubuntu/ocp-install/install-config.yaml.bak | awk '{print \$2}'")
CLUSTER_DOMAIN="$CLUSTER_NAME.$BASE_DOMAIN"

NODE_IPS=(
  "bootstrap:10.0.1.20"
  "master0:10.0.1.21"
  "master1:10.0.1.22"
  "master2:10.0.1.23"
  "worker0:10.0.1.24"
  "worker1:10.0.1.25"
)

for ENTRY in "${NODE_IPS[@]}"; do
  NODE_NAME="${ENTRY%%:*}"
  NODE_IP="${ENTRY##*:}"
  echo "  Waiting for $NODE_NAME ($NODE_IP) to boot RHCOS..."
  until bastion_ssh "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@$NODE_IP 'cat /etc/os-release | grep -q RHCOS'" 2>/dev/null; do
    echo "    $(date) — $NODE_NAME not yet running RHCOS, waiting..."
    sleep 20
  done
  echo "    $NODE_NAME is running RHCOS!"
done

# ── 5. Add /etc/hosts on all nodes ───────────────────────────────────────────
echo ""
echo "==> [5/5] Ensuring DNS /etc/hosts on all nodes..."
for ENTRY in "${NODE_IPS[@]}"; do
  NODE_IP="${ENTRY##*:}"
  bastion_ssh "ssh -o StrictHostKeyChecking=no core@$NODE_IP \
    'grep -q api.$CLUSTER_DOMAIN /etc/hosts || \
     echo \"10.0.1.20 api.$CLUSTER_DOMAIN api-int.$CLUSTER_DOMAIN\" | sudo tee -a /etc/hosts'" \
    2>/dev/null || echo "  (could not reach $NODE_IP yet — may self-configure via dnsmasq)"
done

echo ""
echo "============================================"
echo " ALL NODES ARE RUNNING RHCOS"
echo "============================================"
echo ""
echo "Next steps — run on the bastion:"
echo ""
echo "  ssh -i $SSH_KEY ubuntu@$BASTION_IP"
echo ""
echo "  # Monitor bootstrap (takes 20-30 min):"
echo "  openshift-install wait-for bootstrap-complete \\"
echo "    --dir=~/ocp-install --log-level=info"
echo ""
echo "  # After bootstrap completes, approve worker CSRs:"
echo "  export KUBECONFIG=~/ocp-install/auth/kubeconfig"
echo "  oc get csr | grep Pending | awk '{print \$1}' | xargs oc adm certificate approve"
echo ""
echo "  # Wait for full install (takes 45-60 min total):"
echo "  openshift-install wait-for install-complete \\"
echo "    --dir=~/ocp-install --log-level=info"
echo ""
echo "  # Get console credentials:"
echo "  cat ~/ocp-install/auth/kubeadmin-password"
echo "  echo Console: https://console-openshift-console.apps.$CLUSTER_DOMAIN"
