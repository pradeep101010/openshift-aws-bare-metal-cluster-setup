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
export NODE_SSH_KEY='${node_ssh_private_key}'
export STORAGE_IPS="${storage_ips}"

# Fix hostname
echo "127.0.0.1 $(hostname)" >> /etc/hosts

# Fix DNS
systemctl disable systemd-resolved
systemctl stop systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Wait for DNS
for i in {1..10}; do
  nslookup raw.githubusercontent.com &>/dev/null && break
  echo "Waiting for DNS... attempt $i"
  sleep 5
done
# Get latest commit SHA to bypass CDN cache
SHA=$(curl -sf "https://api.github.com/repos/pradeep101010/openshift-aws-bare-metal-cluster-setup/commits/main" | grep '"sha"' | head -1 | cut -d'"' -f4)
echo "Fetching commit: $SHA"

# Write node SSH key (passed from Terraform, not GitHub)
mkdir -p /home/ubuntu/.ssh
echo "$NODE_SSH_KEY" > /home/ubuntu/.ssh/openshift-poc-rhcos-node.pem
chmod 600 /home/ubuntu/.ssh/openshift-poc-rhcos-node.pem
chown -R ubuntu:ubuntu /home/ubuntu/.ssh

# Fetch and run bastion-init.sh
curl -sf "https://raw.githubusercontent.com/pradeep101010/openshift-aws-bare-metal-cluster-setup/$SHA/scripts/bastion-init.sh" \
  -o /tmp/bastion-init.sh
chmod +x /tmp/bastion-init.sh
bash /tmp/bastion-init.sh