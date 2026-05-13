#!/bin/bash
set -euo pipefail
exec > /var/log/bastion-init.log 2>&1

# Variables from Terraform
export CLUSTER_NAME="${cluster_name}"
export BASE_DOMAIN="${base_domain}"
export OCP_VERSION="${ocp_version}"
export PULL_SECRET='${pull_secret}'
export SSH_PUBLIC_KEY='${ssh_public_key}'
export BASTION_IP="${bastion_ip}"
export BOOTSTRAP_IP="${bootstrap_ip}"
export MASTER0_IP="${master0_ip}"
export MASTER1_IP="${master1_ip}"
export MASTER2_IP="${master2_ip}"
export WORKER_IPS="${worker_ips}"
export SUBNET_CIDR="${subnet_cidr}"

# Fix DNS before fetching from GitHub
rm -f /etc/resolv.conf
echo "nameserver 169.254.169.253" > /etc/resolv.conf

# Wait for DNS to be ready
for i in {1..10}; do
  nslookup raw.githubusercontent.com &>/dev/null && break
  echo "Waiting for DNS... attempt $i"
  sleep 5
done

# Fetch the real script from GitHub and run it
REPO_URL="https://raw.githubusercontent.com/pradeep101010/openshift-aws-bare-metal-cluster-setup/main"
curl -sf "$REPO_URL/scripts/bastion-init.sh" -o /tmp/bastion-init.sh
chmod +x /tmp/bastion-init.sh
bash /tmp/bastion-init.sh