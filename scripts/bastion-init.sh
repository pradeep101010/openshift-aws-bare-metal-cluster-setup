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

# Build one *.apps record per worker — dnsmasq round-robins across them
APPS_RECORDS=""
for ip in $WORKER_IPS; do
  APPS_RECORDS="${APPS_RECORDS}address=/.apps.$CLUSTER_DOMAIN/$ip"$'\n'
done

cat > /etc/dnsmasq.conf << EOF
port=53
bind-interfaces
listen-address=127.0.0.1,$BASTION_IP
server=169.254.169.253

address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP
address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP
${APPS_RECORDS}
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

# ── 12. Flip DNS bootstrap → masters (round-robin across all 3) ───────────────
# Was: single sed pin to MASTER0_IP. That's a single point of failure — if
# master0 has any issue, the bastion (and anything resolving via it) loses
# access to the cluster API entirely.
#
# Instead, write 3 address records for api and 3 for api-int — dnsmasq
# round-robins among them. Surviving any one master failure is automatic.

# Remove the old bootstrap-pinned entries
sed -i "\|address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|d"     /etc/dnsmasq.conf
sed -i "\|address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|d" /etc/dnsmasq.conf

# Write 3 lines each for api and api-int
cat >> /etc/dnsmasq.conf <<EOF

# API endpoints — round-robin across all masters
address=/api.$CLUSTER_DOMAIN/$MASTER0_IP
address=/api.$CLUSTER_DOMAIN/$MASTER1_IP
address=/api.$CLUSTER_DOMAIN/$MASTER2_IP
address=/api-int.$CLUSTER_DOMAIN/$MASTER0_IP
address=/api-int.$CLUSTER_DOMAIN/$MASTER1_IP
address=/api-int.$CLUSTER_DOMAIN/$MASTER2_IP
EOF

# /etc/hosts can't round-robin (only first match wins), so remove api entries
# entirely and let dnsmasq handle resolution.
sed -i "/api\.$CLUSTER_DOMAIN/d" /etc/hosts
sed -i "/api-int\.$CLUSTER_DOMAIN/d" /etc/hosts

# Validate before restarting
if ! dnsmasq --test 2>&1; then
  echo "FATAL: dnsmasq config invalid"
  cat /etc/dnsmasq.conf
  exit 1
fi

systemctl restart dnsmasq

echo "==> DNS flipped to round-robin across masters"

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

# ── 14. Wait until cluster is usable (non-blocking install-complete) ─────────
export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig

echo "==> Waiting for OpenShift API..." | tee -a /var/log/bastion-init.log
until oc whoami >/dev/null 2>&1; do
  echo "  API not ready yet..." | tee -a /var/log/bastion-init.log
  sleep 10
done

echo "==> API is reachable" | tee -a /var/log/bastion-init.log

echo "==> Waiting for control plane nodes..." | tee -a /var/log/bastion-init.log
until [ "$(oc get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge 3 ]; do
  oc get nodes 2>/dev/null | tee -a /var/log/bastion-init.log || true
  sleep 15
done

echo "==> Control plane nodes are Ready" | tee -a /var/log/bastion-init.log

echo "==> Waiting for ingress deployment..." | tee -a /var/log/bastion-init.log
until oc -n openshift-ingress get deploy/router-default >/dev/null 2>&1; do
  sleep 10
done

echo "==> Cluster is usable — continuing automation" | tee -a /var/log/bastion-init.log

# Run install-complete in background only for monitoring/logging
nohup sudo -u ubuntu openshift-install wait-for install-complete \
  --dir=$INSTALL_DIR --log-level=info \
  >> /var/log/install-complete.log 2>&1 &

echo "==> Background install-complete watcher started" | tee -a /var/log/bastion-init.log

# ── 15. Patch mastersSchedulable: false and reschedule routers ────────────────
# Masters were schedulable during install (compute.replicas=0). Now that real
# workers exist, take the worker role off masters so workloads (including
# routers) only land on workers.
echo "==> Patching mastersSchedulable=false"
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":false}}'

# Existing router pods stay on masters until evicted — delete them so the
# deployment recreates them onto the (now only) worker nodes.
echo "==> Forcing router pods to reschedule onto workers"
oc -n openshift-ingress delete pod --all

# Wait for all router pods to come back Running
echo "==> Waiting for routers to be Running..."
for i in $(seq 1 30); do
  TOTAL=$(oc -n openshift-ingress get pods --no-headers 2>/dev/null | wc -l)
  RUNNING=$(oc -n openshift-ingress get pods --no-headers 2>/dev/null | grep -c Running || echo 0)
  if [ "$RUNNING" -ge "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "==> All $TOTAL router pods Running"
    break
  fi
  echo "  attempt $i/30 — $RUNNING/$TOTAL routers Running"
  sleep 10
done

# Let cluster operators (auth, console) recover after router move
sleep 30
echo "==> Master/worker separation complete"

# ── 16. Terminate bootstrap ───────────────────────────────────────────────────
BOOTSTRAP_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$BOOTSTRAP_IP" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "$REGION" --output text)
aws ec2 terminate-instances --instance-ids "$BOOTSTRAP_INSTANCE" --region "$REGION"

# ── 17. Apply autoscaler manifests ────────────────────────────────────────────
REPO_URL="https://raw.githubusercontent.com/pradeep101010/openshift-aws-bare-metal-cluster-setup/main"

curl -sf "$REPO_URL/autoscaler/manifests/machineset.yaml" \
  | sed "s/__CLUSTER_NAME__/$CLUSTER_NAME/g; s/__WORKER_COUNT__/$WORKER_COUNT/g" \
  | oc apply -f -
curl -sf "$REPO_URL/autoscaler/manifests/cluster-autoscaler.yaml" | oc apply -f -
curl -sf "$REPO_URL/autoscaler/manifests/machine-autoscaler.yaml" \
  | sed "s/__WORKER_COUNT__/$WORKER_COUNT/g" | oc apply -f -

# ── 18. Publish autoscaler files ──────────────────────────────────────────────
mkdir -p $WEB_ROOT/autoscaler $WEB_ROOT/auth $WEB_ROOT/scripts 
mkdir -p $WEB_ROOT/autoscaler $WEB_ROOT/auth
curl -sf "$REPO_URL/autoscaler/webhook.py"             -o $WEB_ROOT/autoscaler/webhook.py
curl -sf "$REPO_URL/autoscaler/watcher.py"             -o $WEB_ROOT/autoscaler/watcher.py
curl -sf "$REPO_URL/autoscaler/requirements.txt"       -o $WEB_ROOT/autoscaler/requirements.txt
curl -sf "$REPO_URL/autoscaler/ocp-autoscaler.service" -o $WEB_ROOT/autoscaler/ocp-autoscaler.service

# Ignition stub template — used by webhook.py to generate user-data for new RHCOS workers
curl -sf "$REPO_URL/terraform/scripts/ignition-stub.json.tpl" \
  -o $WEB_ROOT/scripts/ignition-stub.json.tpl

# Kubeconfig for the autoscaler EC2 to talk to the cluster
cp $INSTALL_DIR/auth/kubeconfig $WEB_ROOT/auth/kubeconfig
chmod 644 $WEB_ROOT/auth/kubeconfig

chown -R www-data:www-data $WEB_ROOT/autoscaler $WEB_ROOT/auth


# ── 19. Permanent CSR approval service ────────────────────────────────────────
curl -sf "$REPO_URL/scripts/csr-approver.service" \
  -o /etc/systemd/system/csr-approver.service

touch /var/log/csr-approver.log
chown ubuntu:ubuntu /var/log/csr-approver.log

systemctl daemon-reload
systemctl enable --now csr-approver.service

echo "==> CSR approver service started"
echo "==> Cluster ready"

#-- 20. Make bastian reconstruct DNS records for node ingress traffic for new nodes-
cat > /usr/local/bin/refresh-apps-dns.sh << 'EOF'
#!/bin/bash
set -euo pipefail
exec >> /var/log/refresh-apps-dns.log 2>&1

CONF=/etc/dnsmasq.conf
CLUSTER_DOMAIN=${1:?usage: $0 <cluster-domain>}
KUBECONFIG=/home/ubuntu/ocp-install/auth/kubeconfig
export KUBECONFIG

WORKER_IPS=$(oc get nodes \
  -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
  -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
  2>/dev/null | sort -u)

if [ -z "$WORKER_IPS" ]; then
  echo "$(date) FATAL: no worker IPs found — leaving dnsmasq unchanged"
  exit 1
fi

echo "$(date) Refreshing *.apps DNS for workers:"
echo "$WORKER_IPS" | sed 's/^/  /'

sed -i "\|address=/.apps.$CLUSTER_DOMAIN/|d" $CONF

NEW_BLOCK=""
for ip in $WORKER_IPS; do
  NEW_BLOCK="${NEW_BLOCK}address=/.apps.$CLUSTER_DOMAIN/$ip"$'\n'
done

if grep -q "etcd-0.$CLUSTER_DOMAIN" $CONF; then
  awk -v block="$NEW_BLOCK" '/etcd-0/ && !done {print block; done=1} 1' $CONF > $CONF.new
  mv $CONF.new $CONF
else
  echo "$NEW_BLOCK" >> $CONF
fi

systemctl restart dnsmasq
echo "$(date) dnsmasq restarted"
EOF

sudo chmod +x /usr/local/bin/refresh-apps-dns.sh
sudo touch /var/log/refresh-apps-dns.log
sudo chown ubuntu:ubuntu /var/log/refresh-apps-dns.log

#-- 21. Expose it as HTTP endpoint so webhook.py can call it after scaling events --
sudo mkdir -p /var/www/cgi-bin

sudo tee /var/www/cgi-bin/refresh-dns.sh > /dev/null <<'EOF'
#!/bin/bash
echo "Content-type: text/plain"
echo ""

# Lock so concurrent calls don't trample each other
exec 200>/var/run/refresh-dns.lock
flock -n 200 || { echo "another refresh in progress"; exit 0; }

CLUSTER_DOMAIN=$(cat /etc/dnsmasq.conf | grep -oP 'api\.\K[^/]+' | head -1)
/usr/local/bin/refresh-apps-dns.sh "$CLUSTER_DOMAIN" 2>&1
EOF

sudo chmod +x /var/www/cgi-bin/refresh-dns.sh
#-- 22. configure apache to enable CGI script--
sudo a2enmod cgi 2>/dev/null || true

# Make sure /cgi-bin/ is mapped to /var/www/cgi-bin/
# Check existing config:
grep -r "cgi-bin" /etc/apache2/ | head

# If not configured, add to /etc/apache2/conf-enabled/ocp.conf or similar:
sudo tee /etc/apache2/conf-available/cgi.conf > /dev/null <<'EOF'
ScriptAlias /cgi-bin/ /var/www/cgi-bin/
<Directory /var/www/cgi-bin>
    AllowOverride None
    Options +ExecCGI
    Require all granted
</Directory>
EOF

sudo a2enconf cgi
sudo systemctl reload apache2
# Apache needs to run CGI as root
sudo tee /etc/sudoers.d/dns-refresh > /dev/null <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/refresh-apps-dns.sh, /usr/bin/systemctl restart dnsmasq
EOF
sudo chmod 440 /etc/sudoers.d/dns-refresh
sudo sed -i 's|/usr/local/bin/refresh-apps-dns.sh|sudo /usr/local/bin/refresh-apps-dns.sh|' /var/www/cgi-bin/refresh-dns.sh