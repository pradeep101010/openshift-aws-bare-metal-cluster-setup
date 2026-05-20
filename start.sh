#!/bin/bash
# =============================================================================
#   OCP Cluster Bootstrap Orchestrator
#   Runs from your local machine. Orchestrates 3-phase Terraform apply:
#     1. Bastion → publishes ignition files
#     2. Bootstrap + masters → form control plane
#     3. Workers + autoscaler → join cluster
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SSH_KEY="${SSH_KEY:-$HOME/Downloads/openshift-poc-rhcos-node.pem}"
POLL_INTERVAL=30
MAX_WAIT_MINUTES=60

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()     { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $*"; }
fail()   { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*"; exit 1; }
phase()  { echo -e "\n${BLUE}════════════════════════════════════════${NC}"
           echo -e "${BLUE} $*${NC}"
           echo -e "${BLUE}════════════════════════════════════════${NC}\n"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_url() {
  local url=$1
  local description=$2
  local max_attempts=$((MAX_WAIT_MINUTES * 60 / POLL_INTERVAL))

  log "Polling: $description"
  log "  URL: $url"

  for i in $(seq 1 $max_attempts); do
    if curl -sf --max-time 10 "$url" > /dev/null 2>&1; then
      ok "$description"
      return 0
    fi
    echo -n "."
    sleep $POLL_INTERVAL
  done

  echo
  fail "Timeout waiting for: $description (waited ${MAX_WAIT_MINUTES} min)"
}

wait_for_ssh_log() {
  local bastion_ip=$1
  local pattern=$2
  local description=$3
  local max_attempts=$((MAX_WAIT_MINUTES * 60 / POLL_INTERVAL))

  log "Watching bastion log for: $description"

  for i in $(seq 1 $max_attempts); do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
         ubuntu@$bastion_ip "sudo grep -q '$pattern' /var/log/bastion-init.log" 2>/dev/null; then
      ok "$description"
      return 0
    fi
    echo -n "."
    sleep $POLL_INTERVAL
  done

  echo
  fail "Timeout waiting for log pattern: $pattern"
}

# ── Sanity check ──────────────────────────────────────────────────────────────
[ -f "$SSH_KEY" ] || fail "SSH key not found: $SSH_KEY"
command -v terraform > /dev/null || fail "terraform not in PATH"
command -v curl > /dev/null      || fail "curl not in PATH"
[ -f "terraform.tfvars" ] || fail "terraform.tfvars not found in current directory"

phase "OCP Cluster Bootstrap — $(date)"
log "SSH key: $SSH_KEY"

# ── Phase 1: Bastion ──────────────────────────────────────────────────────────
phase "Phase 1: Provisioning bastion"

terraform apply -target=aws_instance.bastion -auto-approve

BASTION_IP=$(terraform output -raw bastion_public_ip)
ok "Bastion launched: $BASTION_IP"

log "Waiting for bastion userdata to complete (Apache + ignition files)..."
wait_for_url "http://$BASTION_IP/ignition/bootstrap.ign" "Bastion serving ignition files"
wait_for_url "http://$BASTION_IP/ready"                   "Bastion READY marker"

# ── Phase 2: Bootstrap + Masters ──────────────────────────────────────────────
phase "Phase 2: Provisioning bootstrap + masters"

terraform apply -target=aws_instance.ocp_node -auto-approve
ok "Bootstrap + masters launched"

log "Waiting for bootstrap-complete (masters form etcd, MCS comes up)..."
log "This takes ~15-20 minutes"
wait_for_ssh_log "$BASTION_IP" "bootstrap-complete" "Bootstrap complete — masters running cluster"

log "Waiting for DNS flip to master0..."
wait_for_ssh_log "$BASTION_IP" "DNS updated" "DNS flipped bootstrap → master0"

# ── Phase 3: Workers + Autoscaler ─────────────────────────────────────────────
phase "Phase 3: Provisioning workers + autoscaler"

terraform apply -auto-approve
ok "Workers + autoscaler launched"

log "Waiting for all worker CSRs to be approved..."
log "This takes ~10-15 minutes"
wait_for_ssh_log "$BASTION_IP" "All .* nodes Ready" "All nodes Ready"

log "Waiting for install-complete (cluster operators stabilize)..."
log "This takes ~20-30 minutes"
wait_for_ssh_log "$BASTION_IP" "OCP CLUSTER READY" "Cluster fully installed"

# ── Final output ──────────────────────────────────────────────────────────────
phase "Cluster ready"

CLUSTER_NAME=$(grep cluster_name terraform.tfvars | head -1 | cut -d'"' -f2)
BASE_DOMAIN=$(grep base_domain terraform.tfvars | head -1 | cut -d'"' -f2)

ok "Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
ok "API:     https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
ok "Bastion: ssh -i $SSH_KEY ubuntu@$BASTION_IP"
echo
log "Get kubeadmin password from bastion:"
echo "  ssh -i $SSH_KEY ubuntu@$BASTION_IP 'cat /home/ubuntu/ocp-install/auth/kubeadmin-password'"
echo
log "Or fetch kubeconfig:"
echo "  scp -i $SSH_KEY ubuntu@$BASTION_IP:/home/ubuntu/ocp-install/auth/kubeconfig ./kubeconfig"
echo "  export KUBECONFIG=\$PWD/kubeconfig"
echo "  oc get nodes"