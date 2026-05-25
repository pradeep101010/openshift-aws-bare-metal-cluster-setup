#!/bin/bash
set -euo pipefail
exec >> /var/log/bastion-init.log 2>&1

echo "============================================"
echo " OCP Bastion Init — $(date)"
echo "============================================"

# Env vars from bootstrap script:
# CLUSTER_NAME, BASE_DOMAIN, OCP_VERSION, BASTION_IP, BOOTSTRAP_IP,
# MASTER0_IP, MASTER1_IP, MASTER2_IP, WORKER_IPS, SUBNET_CIDR,
# PULL_SECRET, SSH_PUBLIC_KEY

BASE_WORKER_IP="10.0.1"
BASE_WORKER_OFFSET=24
REGION=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" | \
  xargs -I{} curl -s -H "X-aws-ec2-metadata-token: {}" \
  http://169.254.169.254/latest/meta-data/placement/region)

CLUSTER_DOMAIN="$CLUSTER_NAME.$BASE_DOMAIN"
WEB_ROOT="/var/www/html"
INSTALL_DIR="/home/ubuntu/ocp-install"

WORKER_COUNT=$(echo $WORKER_IPS | wc -w)
EXPECTED_NODES=$((3 + WORKER_COUNT))

echo "$BASTION_IP $(hostname)" >> /etc/hosts

# ── 1. System packages ────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apache2 dnsmasq curl wget jq python3 awscli net-tools bind9-dnsutils

# ── 2. Configure dnsmasq ──────────────────────────────────────────────────────
systemctl disable --now systemd-resolved || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver 169.254.169.253
EOF

FIRST_WORKER_IP=$(echo $WORKER_IPS | awk '{print $1}')

cat > /etc/dnsmasq.conf << EOF
port=53
bind-interfaces
listen-address=127.0.0.1,$BASTION_IP
server=169.254.169.253

address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP
address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP
address=/.apps.$CLUSTER_DOMAIN/$FIRST_WORKER_IP

address=/etcd-0.$CLUSTER_DOMAIN/$MASTER0_IP
address=/etcd-1.$CLUSTER_DOMAIN/$MASTER1_IP
address=/etcd-2.$CLUSTER_DOMAIN/$MASTER2_IP

srv-host=_etcd-server-ssl._tcp.$CLUSTER_DOMAIN,etcd-0.$CLUSTER_DOMAIN,2380,0,10
srv-host=_etcd-server-ssl._tcp.$CLUSTER_DOMAIN,etcd-1.$CLUSTER_DOMAIN,2380,0,10
srv-host=_etcd-server-ssl._tcp.$CLUSTER_DOMAIN,etcd-2.$CLUSTER_DOMAIN,2380,0,10
EOF

systemctl enable dnsmasq && systemctl restart dnsmasq
sleep 2

# ── 3. Apache file server ─────────────────────────────────────────────────────
mkdir -p $WEB_ROOT/ignition

cat > /etc/apache2/conf-available/ocp.conf << 'APACHEEOF'
<Directory /var/www/html>
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
APACHEEOF

a2enconf ocp
systemctl enable apache2 && systemctl restart apache2

# ── 4. Download openshift-install + oc ────────────────────────────────────────
OCP_MIRROR="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION"
cd /tmp
wget "$OCP_MIRROR/openshift-install-linux.tar.gz" -O openshift-install.tar.gz
wget "$OCP_MIRROR/openshift-client-linux.tar.gz"  -O oc.tar.gz
gzip -t openshift-install.tar.gz || { echo "FATAL: corrupt"; exit 1; }
gzip -t oc.tar.gz                || { echo "FATAL: corrupt"; exit 1; }
tar -xzf openshift-install.tar.gz && tar -xzf oc.tar.gz
mv openshift-install oc kubectl /usr/local/bin/

# ── 5. SSH key for node access ────────────────────────────────────────────────
mkdir -p /home/ubuntu/.ssh
echo "$NODE_SSH_KEY" > /home/ubuntu/.ssh/openshift-poc-rhcos-node.pem
chmod 600 /home/ubuntu/.ssh/openshift-poc-rhcos-node.pem

cat > /home/ubuntu/.ssh/config << 'EOF'
Host 10.0.1.*
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
chmod 600 /home/ubuntu/.ssh/config
chown -R ubuntu:ubuntu /home/ubuntu/.ssh

# ── 6. Generate ignition configs ──────────────────────────────────────────────
mkdir -p $INSTALL_DIR
chown ubuntu:ubuntu $INSTALL_DIR

cat > $INSTALL_DIR/install-config.yaml << INSTALLEOF
apiVersion: v1
baseDomain: $BASE_DOMAIN
metadata:
  name: $CLUSTER_NAME
compute:
- hyperthreading: Enabled
  name: worker
  replicas: 0
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: 3
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: $SUBNET_CIDR
platform:
  none: {}
fips: false
pullSecret: '$PULL_SECRET'
sshKey: '$SSH_PUBLIC_KEY'
INSTALLEOF

chown ubuntu:ubuntu $INSTALL_DIR/install-config.yaml
cp $INSTALL_DIR/install-config.yaml $INSTALL_DIR/install-config.yaml.bak

cd $INSTALL_DIR
sudo -u ubuntu openshift-install create ignition-configs --dir=. --log-level=info

# ── 7. Publish ignition files ─────────────────────────────────────────────────
cp $INSTALL_DIR/bootstrap.ign $WEB_ROOT/ignition/
cp $INSTALL_DIR/master.ign    $WEB_ROOT/ignition/
cp $INSTALL_DIR/worker.ign    $WEB_ROOT/ignition/
chmod 644 $WEB_ROOT/ignition/*.ign
chown -R www-data:www-data $WEB_ROOT

# ── 8. /etc/hosts ─────────────────────────────────────────────────────────────
cat >> /etc/hosts << EOF
$BOOTSTRAP_IP api.$CLUSTER_DOMAIN api-int.$CLUSTER_DOMAIN
$MASTER0_IP etcd-0.$CLUSTER_DOMAIN
$MASTER1_IP etcd-1.$CLUSTER_DOMAIN
$MASTER2_IP etcd-2.$CLUSTER_DOMAIN
EOF

# ── 9. kubeconfig ─────────────────────────────────────────────────────────────
cp $INSTALL_DIR/auth/kubeconfig /home/ubuntu/kubeconfig
echo "export KUBECONFIG=/home/ubuntu/ocp-install/auth/kubeconfig" >> /home/ubuntu/.bashrc
chown ubuntu:ubuntu /home/ubuntu/kubeconfig

# ── 10. Signal ready — nodes can now fetch ignition ───────────────────────────
echo "READY" > $WEB_ROOT/ready
chown www-data:www-data $WEB_ROOT/ready

echo "==> BASTION READY — ignition files served, nodes will fetch on boot"

# ── 11. Wait for bootstrap-complete ───────────────────────────────────────────
chown -R ubuntu:ubuntu $INSTALL_DIR
sudo -u ubuntu openshift-install wait-for bootstrap-complete \
  --dir=$INSTALL_DIR --log-level=info 2>&1 | tee -a /var/log/bastion-init.log || true
echo "==> bootstrap-complete reached"

# ── 12. Flip DNS bootstrap → master0 ──────────────────────────────────────────
sed -i "s|address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|address=/api.$CLUSTER_DOMAIN/$MASTER0_IP|" /etc/dnsmasq.conf
sed -i "s|address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|address=/api-int.$CLUSTER_DOMAIN/$MASTER0_IP|" /etc/dnsmasq.conf
sed -i "s|$BOOTSTRAP_IP api.$CLUSTER_DOMAIN|$MASTER0_IP api.$CLUSTER_DOMAIN|" /etc/hosts
systemctl restart dnsmasq

export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig

# ── 13. Approve worker CSRs ───────────────────────────────────────────────────
for round in 1 2; do
  sleep 60
  PENDING=$(oc get csr 2>/dev/null | grep Pending | awk '{print $1}' || true)
  [ -n "$PENDING" ] && echo "$PENDING" | xargs oc adm certificate approve
done

until [ "$(oc get nodes --no-headers 2>/dev/null | grep -c Ready)" = "$EXPECTED_NODES" ]; do
  PENDING=$(oc get csr 2>/dev/null | grep Pending | awk '{print $1}' || true)
  [ -n "$PENDING" ] && echo "$PENDING" | xargs oc adm certificate approve
  sleep 15
done

# ── 14. Wait for install-complete ─────────────────────────────────────────────
sudo -u ubuntu openshift-install wait-for install-complete \
  --dir=$INSTALL_DIR --log-level=info 2>&1 | tee -a /var/log/bastion-init.log

# ── 15. Terminate bootstrap ───────────────────────────────────────────────────
BOOTSTRAP_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$BOOTSTRAP_IP" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "$REGION" --output text)
aws ec2 terminate-instances --instance-ids "$BOOTSTRAP_INSTANCE" --region "$REGION"

# ── 16. Apply autoscaler manifests ────────────────────────────────────────────
REPO_URL="https://raw.githubusercontent.com/pradeep101010/openshift-aws-bare-metal-cluster-setup/main"

curl -sf "$REPO_URL/autoscaler/manifests/machineset.yaml" \
  | sed "s/__CLUSTER_NAME__/$CLUSTER_NAME/g; s/__WORKER_COUNT__/$WORKER_COUNT/g" \
  | oc apply -f -
curl -sf "$REPO_URL/autoscaler/manifests/cluster-autoscaler.yaml" | oc apply -f -
curl -sf "$REPO_URL/autoscaler/manifests/machine-autoscaler.yaml" \
  | sed "s/__WORKER_COUNT__/$WORKER_COUNT/g" | oc apply -f -

# ── 17. Publish autoscaler files ──────────────────────────────────────────────
mkdir -p $WEB_ROOT/autoscaler $WEB_ROOT/auth
curl -sf "$REPO_URL/autoscaler/webhook.py"             -o $WEB_ROOT/autoscaler/webhook.py
curl -sf "$REPO_URL/autoscaler/watcher.py"             -o $WEB_ROOT/autoscaler/watcher.py
curl -sf "$REPO_URL/autoscaler/requirements.txt"       -o $WEB_ROOT/autoscaler/requirements.txt
curl -sf "$REPO_URL/autoscaler/ocp-autoscaler.service" -o $WEB_ROOT/autoscaler/ocp-autoscaler.service

cp $INSTALL_DIR/auth/kubeconfig $WEB_ROOT/auth/kubeconfig
chmod 644 $WEB_ROOT/auth/kubeconfig
chown -R www-data:www-data $WEB_ROOT/autoscaler $WEB_ROOT/auth

# ── 18. Permanent CSR approval service ────────────────────────────────────────
curl -sf "$REPO_URL/scripts/csr-approver.service" \
  -o /etc/systemd/system/csr-approver.service

touch /var/log/csr-approver.log
chown ubuntu:ubuntu /var/log/csr-approver.log

systemctl daemon-reload
systemctl enable --now csr-approver.service

echo "==> CSR approver service started"
echo "==> Cluster ready"