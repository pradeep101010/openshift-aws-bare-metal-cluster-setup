#!/bin/bash
# =============================================================================
#
#   1. Fix DNS to 169.254.169.253 BEFORE apt-get (circular dependency)
#   2. Add bastion hostname to /etc/hosts (fixes sudo warnings)
#   3. Verify tar downloads before extracting (silent corruption)
#   4. Download coreos-installer and serve it (nodes never hit internet)
#   5. coreos-installer must be chmod 755 (executable)
#   6. Run openshift-install as ubuntu user (permission issues as root)
#   7. After bootstrap completes, update DNS to point to master0
#   8. Attach IAM role to bastion so AWS CLI works without credentials
#   9. After bootstrap, run wait-for-install-complete automatically
# =============================================================================
set -euo pipefail
exec > /var/log/bastion-init.log 2>&1

echo "============================================"
echo " OCP Bastion Init — $(date)"
echo "============================================"

CLUSTER_NAME="${cluster_name}"
BASE_DOMAIN="${base_domain}"
OCP_VERSION="${ocp_version}"
BASTION_IP="${bastion_ip}"
BOOTSTRAP_IP="${bootstrap_ip}"
MASTER0_IP="${master0_ip}"
MASTER1_IP="${master1_ip}"
MASTER2_IP="${master2_ip}"
WORKER0_IP="${worker0_ip}"
WORKER1_IP="${worker1_ip}"
SUBNET_CIDR="${subnet_cidr}"
REGION=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" | \
  xargs -I{} curl -s -H "X-aws-ec2-metadata-token: {}" \
  http://169.254.169.254/latest/meta-data/placement/region)

CLUSTER_DOMAIN="$CLUSTER_NAME.$BASE_DOMAIN"
WEB_ROOT="/var/www/html"
INSTALL_DIR="/home/ubuntu/ocp-install"

# ── Fix 1: Restore DNS BEFORE installing anything ────────────────────────────
echo "==> Fixing DNS before package install"
rm -f /etc/resolv.conf
echo "nameserver 169.254.169.253" > /etc/resolv.conf

# Fix 2: Add bastion hostname to /etc/hosts to fix sudo warnings
echo "$BASTION_IP $(hostname)" >> /etc/hosts

# ── 1. System packages ────────────────────────────────────────────────────────
echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  apache2 \
  dnsmasq \
  curl wget jq \
  python3 \
  awscli \
  net-tools \
  bind9-dnsutils

# ── 2. Configure dnsmasq ──────────────────────────────────────────────────────
echo "==> Configuring dnsmasq"
systemctl disable --now systemd-resolved || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver 169.254.169.253
EOF

cat > /etc/dnsmasq.conf << EOF
port=53
bind-interfaces
listen-address=127.0.0.1,$BASTION_IP
server=169.254.169.253

# OCP API → bootstrap during install (updated to master0 after bootstrap)
address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP
address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP

# Wildcard ingress → worker0
address=/.apps.$CLUSTER_DOMAIN/$WORKER0_IP

# etcd
address=/etcd-0.$CLUSTER_DOMAIN/$MASTER0_IP
address=/etcd-1.$CLUSTER_DOMAIN/$MASTER1_IP
address=/etcd-2.$CLUSTER_DOMAIN/$MASTER2_IP

# etcd SRV records
srv-host=_etcd-server-ssl._tcp.$CLUSTER_DOMAIN,etcd-0.$CLUSTER_DOMAIN,2380,0,10
srv-host=_etcd-server-ssl._tcp.$CLUSTER_DOMAIN,etcd-1.$CLUSTER_DOMAIN,2380,0,10
srv-host=_etcd-server-ssl._tcp.$CLUSTER_DOMAIN,etcd-2.$CLUSTER_DOMAIN,2380,0,10

log-queries
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq
sleep 2

DNS_CHECK=$(dig +short @127.0.0.1 api.$CLUSTER_DOMAIN 2>/dev/null || echo "FAILED")
echo "==> DNS check: api.$CLUSTER_DOMAIN → $DNS_CHECK"

# ── 3. Apache file server ─────────────────────────────────────────────────────
echo "==> Configuring Apache"
mkdir -p $WEB_ROOT/rhcos $WEB_ROOT/ignition $WEB_ROOT/status

cat > /etc/apache2/conf-available/ocp.conf << 'APACHEEOF'
<Directory /var/www/html>
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
APACHEEOF

a2enconf ocp
systemctl enable apache2
systemctl restart apache2

# ── 4. Download openshift-install ─────────────────────────────────────────────
echo "==> Downloading openshift-install $OCP_VERSION"
OCP_MIRROR="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION"
cd /tmp

wget "$OCP_MIRROR/openshift-install-linux.tar.gz" -O openshift-install.tar.gz
wget "$OCP_MIRROR/openshift-client-linux.tar.gz"  -O oc.tar.gz

# Fix 3: verify before extracting
gzip -t openshift-install.tar.gz || { echo "FATAL: corrupt download"; exit 1; }
gzip -t oc.tar.gz                || { echo "FATAL: corrupt download"; exit 1; }

tar -xzf openshift-install.tar.gz
tar -xzf oc.tar.gz
mv openshift-install oc kubectl /usr/local/bin/
echo "==> $(openshift-install version)"

# ── 5. Download RHCOS metal image ────────────────────────────────────────────
echo "==> Downloading RHCOS metal image (~1GB)"
RHCOS_MIRROR="https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.14/latest"
wget --show-progress \
  "$RHCOS_MIRROR/rhcos-metal.x86_64.raw.gz" \
  -O "$WEB_ROOT/rhcos/rhcos-metal.x86_64.raw.gz"

# Fix 4+5: download coreos-installer and serve it with execute permission
echo "==> Downloading coreos-installer"
wget "https://mirror.openshift.com/pub/openshift-v4/clients/coreos-installer/latest/coreos-installer_amd64" \
  -O "$WEB_ROOT/coreos-installer"
chmod 755 $WEB_ROOT/coreos-installer

# ── 6. Generate ignition configs ─────────────────────────────────────────────
echo "==> Generating ignition configs"
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
pullSecret: '${pull_secret}'
sshKey: '${ssh_public_key}'
INSTALLEOF

chown ubuntu:ubuntu $INSTALL_DIR/install-config.yaml
cp $INSTALL_DIR/install-config.yaml $INSTALL_DIR/install-config.yaml.bak

# Fix 6: run as ubuntu user
cd $INSTALL_DIR
sudo -u ubuntu openshift-install create ignition-configs --dir=. --log-level=info
ls -lh $INSTALL_DIR/*.ign

# ── 7. Publish files ──────────────────────────────────────────────────────────
echo "==> Publishing files"
cp $INSTALL_DIR/bootstrap.ign $WEB_ROOT/ignition/
cp $INSTALL_DIR/master.ign    $WEB_ROOT/ignition/
cp $INSTALL_DIR/worker.ign    $WEB_ROOT/ignition/
chmod 644 $WEB_ROOT/ignition/*.ign $WEB_ROOT/rhcos/rhcos-metal.x86_64.raw.gz
chown -R www-data:www-data $WEB_ROOT

# ── 8. /etc/hosts ─────────────────────────────────────────────────────────────
cat >> /etc/hosts << EOF
$BOOTSTRAP_IP api.$CLUSTER_DOMAIN api-int.$CLUSTER_DOMAIN
$MASTER0_IP etcd-0.$CLUSTER_DOMAIN
$MASTER1_IP etcd-1.$CLUSTER_DOMAIN
$MASTER2_IP etcd-2.$CLUSTER_DOMAIN
EOF

# ── 9. Node status tracking ───────────────────────────────────────────────────
for node in bootstrap master0 master1 master2 worker0 worker1; do
  echo "pending" > $WEB_ROOT/status/$node
done
chown -R www-data:www-data $WEB_ROOT/status

# ── 10. kubeconfig ────────────────────────────────────────────────────────────
cp $INSTALL_DIR/auth/kubeconfig /home/ubuntu/kubeconfig
echo "export KUBECONFIG=/home/ubuntu/ocp-install/auth/kubeconfig" >> /home/ubuntu/.bashrc
chown ubuntu:ubuntu /home/ubuntu/kubeconfig

# ── 11. Signal ready ──────────────────────────────────────────────────────────
echo "READY" > $WEB_ROOT/ready
chown www-data:www-data $WEB_ROOT/ready

echo "==> BASTION READY — nodes can now start"

# ── 12. Wait for all nodes to complete coreos-installer ──────────────────────
echo "==> Waiting for all nodes to complete coreos-installer..."
NODES="bootstrap master0 master1 master2 worker0 worker1"
while true; do
  ALL_DONE=true
  for NODE in $NODES; do
    STATUS=$(cat $WEB_ROOT/status/$NODE 2>/dev/null || echo "pending")
    [ "$STATUS" != "done" ] && ALL_DONE=false
  done
  $ALL_DONE && break
  echo "  $(date) — waiting for nodes..."
  sleep 30
done
echo "==> All nodes completed coreos-installer"

# ── 13. Volume swap for all nodes from bastion ───────────────────────────────
echo "==> Starting volume swap for all nodes"

NODE_IPS="$BOOTSTRAP_IP $MASTER0_IP $MASTER1_IP $MASTER2_IP $WORKER0_IP $WORKER1_IP"

# Collect instance IDs and volumes
declare -a INSTANCES ROOT_VOLS RHCOS_VOLS
for IP in $NODE_IPS; do
  INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=private-ip-address,Values=$IP" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --region "$REGION" --output text)

  ROOT_VOL=$(aws ec2 describe-instances --instance-id "$INSTANCE" --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId' \
    --output text)

  RHCOS_VOL=$(aws ec2 describe-instances --instance-id "$INSTANCE" --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/xvdf`].Ebs.VolumeId' \
    --output text)

  echo "  $IP → instance=$INSTANCE root=$ROOT_VOL rhcos=$RHCOS_VOL"
  INSTANCES+=("$INSTANCE")
  ROOT_VOLS+=("$ROOT_VOL")
  RHCOS_VOLS+=("$RHCOS_VOL")
done

# Stop all
echo "==> Stopping all nodes..."
aws ec2 stop-instances --instance-ids "${INSTANCES[@]}" --region "$REGION"
aws ec2 wait instance-stopped --instance-ids "${INSTANCES[@]}" --region "$REGION"
echo "==> All stopped"

# Detach all
echo "==> Detaching volumes..."
for VOL in "${ROOT_VOLS[@]}" "${RHCOS_VOLS[@]}"; do
  aws ec2 detach-volume --volume-id "$VOL" --region "$REGION" || true
done
sleep 40

# Attach RHCOS as root
echo "==> Attaching RHCOS volumes as root..."
for i in "${!INSTANCES[@]}"; do
  aws ec2 attach-volume \
    --volume-id "${RHCOS_VOLS[$i]}" \
    --instance-id "${INSTANCES[$i]}" \
    --device /dev/sda1 \
    --region "$REGION"
done
sleep 15

# Start all
echo "==> Starting all nodes into RHCOS..."
aws ec2 start-instances --instance-ids "${INSTANCES[@]}" --region "$REGION"
echo "==> Volume swap complete — nodes booting into RHCOS"

# ── 14. Wait for nodes to boot RHCOS ─────────────────────────────────────────
echo "==> Waiting for all nodes to boot RHCOS..."
export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig

for IP in $NODE_IPS; do
  echo "  Waiting for $IP..."
  until ssh -i /home/ubuntu/.ssh/openshift-poc-rhcos-node.pem \
    -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    core@$IP "hostname" > /dev/null 2>&1; do
    sleep 15
  done
  echo "  $IP is running RHCOS"
done

# ── 15. Fix 7: Update DNS from bootstrap to master0 after bootstrap ───────────
echo "==> Waiting for bootstrap-complete..."
chown -R ubuntu:ubuntu $INSTALL_DIR

sudo -u ubuntu openshift-install wait-for bootstrap-complete \
  --dir=$INSTALL_DIR --log-level=info 2>&1 | tee -a /var/log/bastion-init.log || true

# Fix 7: update DNS to point api.* to master0 now that bootstrap is done
echo "==> Updating DNS: api.* → master0 ($MASTER0_IP)"
sed -i "s|address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|address=/api.$CLUSTER_DOMAIN/$MASTER0_IP|" /etc/dnsmasq.conf
sed -i "s|address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|address=/api-int.$CLUSTER_DOMAIN/$MASTER0_IP|" /etc/dnsmasq.conf
sed -i "s|$BOOTSTRAP_IP api.$CLUSTER_DOMAIN|$MASTER0_IP api.$CLUSTER_DOMAIN|" /etc/hosts
systemctl restart dnsmasq
echo "==> DNS updated: api.$CLUSTER_DOMAIN → $(dig +short @127.0.0.1 api.$CLUSTER_DOMAIN)"

# ── 16. Approve worker CSRs (two rounds) ─────────────────────────────────────
echo "==> Approving worker CSRs..."
for round in 1 2; do
  echo "  Round $round..."
  sleep 60
  PENDING=$(oc get csr 2>/dev/null | grep Pending | awk '{print $1}' || true)
  if [ -n "$PENDING" ]; then
    echo "$PENDING" | xargs oc adm certificate approve
    echo "  Approved: $PENDING"
  else
    echo "  No pending CSRs in round $round"
  fi
done

# Keep approving until all workers are Ready
echo "==> Waiting for all nodes to be Ready..."
until [ "$(oc get nodes --no-headers 2>/dev/null | grep -c Ready)" = "5" ]; do
  PENDING=$(oc get csr 2>/dev/null | grep Pending | awk '{print $1}' || true)
  [ -n "$PENDING" ] && echo "$PENDING" | xargs oc adm certificate approve
  sleep 15
done

echo "==> All 5 nodes Ready!"
oc get nodes

# ── 17. Wait for install complete ────────────────────────────────────────────
echo "==> Waiting for install-complete (this takes 30-45 min)..."
sudo -u ubuntu openshift-install wait-for install-complete \
  --dir=$INSTALL_DIR --log-level=info 2>&1 | tee -a /var/log/bastion-init.log

echo ""
echo "============================================"
echo " OCP CLUSTER READY — $(date)"
echo " Console: https://console-openshift-console.apps.$CLUSTER_DOMAIN"
echo " API:     https://api.$CLUSTER_DOMAIN:6443"
echo " kubeadmin password: $(cat $INSTALL_DIR/auth/kubeadmin-password)"
echo "============================================"
