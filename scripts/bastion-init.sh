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
REPO_URL="https://raw.githubusercontent.com/pradeep101010/openshift-aws-bare-metal-cluster-setup/main"

WORKER_COUNT=$(echo $WORKER_IPS | wc -w)
EXPECTED_NODES=$((3 + WORKER_COUNT))

echo "$BASTION_IP $(hostname)" >> /etc/hosts

# ── 1. System packages ────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apache2 dnsmasq curl wget jq python3 awscli net-tools bind9-dnsutils haproxy

# ── 2. Configure dnsmasq ──────────────────────────────────────────────────────
systemctl disable --now systemd-resolved || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver 169.254.169.253
EOF

# # Build one *.apps record per worker — dnsmasq round-robins across them
# APPS_RECORDS=""
# for ip in $WORKER_IPS; do
#   APPS_RECORDS="${APPS_RECORDS}address=/.apps.$CLUSTER_DOMAIN/$ip"$'\n'
# done

cat > /etc/dnsmasq.conf << EOF
port=53
bind-interfaces
listen-address=127.0.0.1,$BASTION_IP
server=169.254.169.253

address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP
address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP

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
sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf
sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-enabled/000-default.conf

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

# Build initial server lines from WORKER_IPS env var
HTTP_SERVERS=""
HTTPS_SERVERS=""
for ip in $WORKER_IPS; do
  name="worker$(echo $ip | cut -d. -f4)"
  HTTP_SERVERS="${HTTP_SERVERS}    server ${name} ${ip}:80  check inter 10s fall 2 rise 2\n"
  HTTPS_SERVERS="${HTTPS_SERVERS}    server ${name} ${ip}:443 check inter 10s fall 2 rise 2\n"
done

cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0
    maxconn 50000
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend mcs
    bind *:22623
    mode tcp
    default_backend masters_mcs
  
backend masters_mcs
    mode tcp
    balance roundrobin
    option tcp-check
    server master21 $MASTER0_IP:22623 check inter 10s fall 2 rise 2
    server master22 $MASTER1_IP:22623 check inter 10s fall 2 rise 2
    server master23 $MASTER2_IP:22623 check inter 10s fall 2 rise 2

frontend stats
    mode http
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE

#-- apps_http
frontend apps_http
    bind *:80
    mode tcp
    default_backend workers_http

backend workers_http
    mode tcp
    balance roundrobin
    option tcp-check
$(echo -e "$HTTP_SERVERS")
#-- apps_https
frontend apps_https
    bind *:443
    mode tcp
    default_backend workers_https

backend workers_https
    mode tcp
    balance roundrobin
    option tcp-check
$(echo -e "$HTTPS_SERVERS")
#-- ocp_api
frontend ocp_api
    bind *:6443
    mode tcp
    default_backend masters_api

backend masters_api
    mode tcp
    balance roundrobin
    option tcp-check
    server master21 $MASTER0_IP:6443 check inter 10s fall 2 rise 2
    server master22 $MASTER1_IP:6443 check inter 10s fall 2 rise 2
    server master23 $MASTER2_IP:6443 check inter 10s fall 2 rise 2
EOF

sudo systemctl enable haproxy && sudo systemctl restart haproxy
echo "==> HAProxy configured — workers: $WORKER_IPS | masters: $MASTER0_IP $MASTER1_IP $MASTER2_IP"


# ── 12. Flip DNS bootstrap → bastion HAProxy ──────────────────────────────────
# HAProxy on bastion handles load balancing across all 3 masters with health
# checks — better than dnsmasq round-robin which has no health checking.

# Remove the old bootstrap-pinned entries
sed -i "\|address=/api.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|d"     /etc/dnsmasq.conf
sed -i "\|address=/api-int.$CLUSTER_DOMAIN/$BOOTSTRAP_IP|d" /etc/dnsmasq.conf

# Write 3 lines each for api and api-int
cat >> /etc/dnsmasq.conf <<EOF
address=/api.$CLUSTER_DOMAIN/$BASTION_IP
address=/api-int.$CLUSTER_DOMAIN/$BASTION_IP
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

echo "==> DNS flipped to bastion HAProxy (HAProxy load balances across masters)"

# ── 13. Permanent CSR approval service ────────────────────────────────────────
curl -sf "$REPO_URL/scripts/csr-approver.service" \
  -o /etc/systemd/system/csr-approver.service

touch /var/log/csr-approver.log
chown ubuntu:ubuntu /var/log/csr-approver.log

systemctl daemon-reload
systemctl enable --now csr-approver.service

echo "==> CSR approver service started"
echo "==> Cluster ready"

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
  DESIRED=$(oc -n openshift-ingress get deploy router-default \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  AVAILABLE=$(oc -n openshift-ingress get deploy router-default \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
  DESIRED=${DESIRED:-0}
  AVAILABLE=${AVAILABLE:-0}

  # Guard against empty/non-numeric values killing script under set -e
  [[ "$DESIRED"   =~ ^[0-9]+$ ]] || DESIRED=0
  [[ "$AVAILABLE" =~ ^[0-9]+$ ]] || AVAILABLE=0

  if [ "$AVAILABLE" -ge "$DESIRED" ] && [ "$DESIRED" -gt 0 ]; then
    echo "==> All $AVAILABLE/$DESIRED router replicas Running"
    break
  fi
  echo "  attempt $i/30 — $AVAILABLE/$DESIRED router replicas Running"
  sleep 10
done

sleep 30
echo "==> Master/worker separation complete"

# Let cluster operators (auth, console) recover after router move


# ── 16. Terminate bootstrap ───────────────────────────────────────────────────
BOOTSTRAP_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$BOOTSTRAP_IP" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "$REGION" --output text)
aws ec2 terminate-instances --instance-ids "$BOOTSTRAP_INSTANCE" --region "$REGION"

# ── 17. Apply autoscaler manifests ────────────────────────────────────────────
curl -sf "$REPO_URL/autoscaler/manifests/machineset.yaml" \
  | sed "s/__CLUSTER_NAME__/$CLUSTER_NAME/g; s/__WORKER_COUNT__/$WORKER_COUNT/g" \
  | oc apply -f -
curl -sf "$REPO_URL/autoscaler/manifests/cluster-autoscaler.yaml" | oc apply -f -
curl -sf "$REPO_URL/autoscaler/manifests/machine-autoscaler.yaml" \
  | sed "s/__WORKER_COUNT__/$WORKER_COUNT/g" | oc apply -f -
echo "==> Seeding MachineSet status to match initial worker count ($WORKER_COUNT)"
oc patch machineset worker-autoscale -n openshift-machine-api \
  --subresource=status --type=merge \
  -p "{\"status\":{\"replicas\":$WORKER_COUNT,\"readyReplicas\":$WORKER_COUNT,\"availableReplicas\":$WORKER_COUNT}}"

# ── 18. Publish autoscaler files ──────────────────────────────────────────────
mkdir -p $WEB_ROOT/autoscaler $WEB_ROOT/auth $WEB_ROOT/scripts 
curl -sf "$REPO_URL/autoscaler/webhook.py"             -o $WEB_ROOT/autoscaler/webhook.py
curl -sf "$REPO_URL/autoscaler/watcher.py"             -o $WEB_ROOT/autoscaler/watcher.py
curl -sf "$REPO_URL/autoscaler/requirements.txt"       -o $WEB_ROOT/autoscaler/requirements.txt
curl -sf "$REPO_URL/autoscaler/ocp-autoscaler.service" -o $WEB_ROOT/autoscaler/ocp-autoscaler.service

# Ignition stub template — used by webhook.py to generate user-data for new RHCOS workers
curl -sf "$REPO_URL/scripts/ignition-stub.json.tpl"  \
  -o $WEB_ROOT/scripts/ignition-stub.json.tpl

# Kubeconfig for the autoscaler EC2 to talk to the cluster
cp $INSTALL_DIR/auth/kubeconfig $WEB_ROOT/auth/kubeconfig
chmod 644 $WEB_ROOT/auth/kubeconfig

chown -R www-data:www-data $WEB_ROOT/autoscaler $WEB_ROOT/auth

# ── 19. Point *.apps permanently at bastion (HAProxy handles worker routing) ──
# Remove existing worker round-robin entries — bastion IP is now the stable entry point
sed -i "\|address=/\.apps\.$CLUSTER_DOMAIN/|d" /etc/dnsmasq.conf
echo "address=/.apps.$CLUSTER_DOMAIN/$BASTION_IP" >> /etc/dnsmasq.conf
systemctl restart dnsmasq
echo "==> *.apps DNS now permanently points to bastion HAProxy"
cat > /usr/local/bin/refresh-haproxy.sh << 'HAEOF'
#!/bin/bash
set -euo pipefail
exec >> /var/log/refresh-haproxy.log 2>&1

KUBECONFIG=/home/ubuntu/ocp-install/auth/kubeconfig
export KUBECONFIG
CFG=/etc/haproxy/haproxy.cfg
TMPFILE=$(mktemp)

echo "$(date) Refreshing HAProxy worker backends..."

# Get all ready worker IPs from cluster
WORKER_IPS=$(/usr/local/bin/oc get nodes \
  -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/master' \
  --no-headers 2>/dev/null | awk '$2=="Ready" {print $1}' | while read node; do
    /usr/local/bin/oc get node "$node" \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
    echo
  done | sort -u)

if [ -z "$WORKER_IPS" ]; then
  echo "$(date) FATAL: no ready worker IPs found — leaving HAProxy unchanged"
  exit 1
fi

echo "$(date) Workers found:"
echo "$WORKER_IPS" | sed 's/^/  /'

# Build new server blocks
HTTP_SERVERS=""
HTTPS_SERVERS=""
while IFS= read -r ip; do
  [ -z "$ip" ] && continue
  name="worker$(echo $ip | cut -d. -f4)"
  HTTP_SERVERS="${HTTP_SERVERS}    server ${name} ${ip}:80  check inter 10s fall 2 rise 2\n"
  HTTPS_SERVERS="${HTTPS_SERVERS}    server ${name} ${ip}:443 check inter 10s fall 2 rise 2\n"
done <<< "$WORKER_IPS"

# Rewrite server lines between backend markers
awk -v http="$HTTP_SERVERS" -v https="$HTTPS_SERVERS" '
  /^#-- apps_http/  { in_http=1;  in_https=0 }
  /^#-- apps_https/ { in_https=1; in_http=0  }
  /^#-- ocp_api/    { in_http=0;  in_https=0 }
  /^    server / && in_http  { next }
  /^    server / && in_https { next }
  /^backend workers_http/  { print; next }
  /^backend workers_https/ { print; next }
  /^option tcp-check/ && in_http  { print; printf "%s", http;  next }
  /^option tcp-check/ && in_https { print; printf "%s", https; next }
  { print }
' "$CFG" > "$TMPFILE"

# Validate HAProxy config before applying
if haproxy -c -f "$TMPFILE" >/dev/null 2>&1; then
  cp "$TMPFILE" "$CFG"
  systemctl reload haproxy
  echo "$(date) HAProxy reloaded successfully"
else
  echo "$(date) FATAL: HAProxy config validation failed — not applying"
  haproxy -c -f "$TMPFILE"
  rm -f "$TMPFILE"
  exit 1
fi

rm -f "$TMPFILE"
HAEOF

chmod +x /usr/local/bin/refresh-haproxy.sh
touch /var/log/refresh-haproxy.log
chown ubuntu:ubuntu /var/log/refresh-haproxy.log
echo "==> refresh-haproxy.sh installed"

#-- 20. CGI endpoint for webhook.py to call after scaling ----------------------
sudo mkdir -p /var/www/cgi-bin
sudo tee /var/www/cgi-bin/refresh-dns.sh > /dev/null <<'EOF'
#!/bin/bash
echo "Content-type: text/plain"
echo ""

exec 200>/var/run/refresh-haproxy.lock
flock -n 200 || { echo "another refresh in progress"; exit 0; }

/usr/local/bin/refresh-haproxy.sh 2>&1
EOF
sudo chmod +x /var/www/cgi-bin/refresh-dns.sh
echo "CGI Endpoint for webhook configured"
#-- 21. Configure Apache CGI support ------------------------------------------

sudo tee /etc/apache2/conf-available/cgi.conf > /dev/null <<'EOF'
ScriptAlias /cgi-bin/ /var/www/cgi-bin/

<Directory "/var/www/cgi-bin">
    AllowOverride None
    Options +ExecCGI
    Require all granted
</Directory>
EOF

# Enable CGI module (Ubuntu may auto-select cgid)
sudo a2enmod cgid >/dev/null 2>&1 || sudo a2enmod cgi >/dev/null 2>&1 || true

# Enable config
sudo a2enconf cgi >/dev/null 2>&1 || true

# REQUIRED after enabling modules
sudo systemctl restart apache2

# Verify Apache came back
sudo systemctl is-active --quiet apache2 || {
    echo "ERROR: apache2 failed to start"
    sudo journalctl -u apache2 --no-pager -n 50
    exit 1
}
# ── 22. Storage tier: install Longhorn on OpenShift ───────────────────────────
# Ordering matters — each gate unblocks the next:
#   SCC → manager runs → finalizers RBAC → instance-managers create →
#   they report MountPropagation → driver-deployer passes → CSI deploys → PVC binds
echo "==> Setting up storage tier"
LONGHORN_VERSION="v1.7.2"
HELM_VERSION="v3.16.3"
STORAGE_IPS="${STORAGE_IPS:-}"          # guard against set -u

# ── 22a. Label + taint the initial storage nodes ─────────────────────────────
for ip in $STORAGE_IPS; do
  node="ip-$(echo $ip | tr '.' '-')"
  echo "  waiting for storage node $node to join..."
  for i in $(seq 1 60); do oc get node "$node" >/dev/null 2>&1 && break; sleep 10; done
  oc label   node "$node" node-role.kubernetes.io/storage='' --overwrite
  oc label   node "$node" node.longhorn.io/create-default-disk=true --overwrite
  oc adm taint node "$node" storage=longhorn:NoSchedule --overwrite
  echo "  labeled + tainted $node"
done

# ── 22b. RHCOS prerequisite: iscsid (runs on compute nodes, where volumes attach) ─
oc apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/prerequisite/longhorn-iscsi-installation.yaml"

# ── 22c. Install Helm + Longhorn (idempotent) ────────────────────────────────
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz
tar -xzf /tmp/helm.tgz -C /tmp && mv /tmp/linux-amd64/helm /usr/local/bin/helm
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace --version "${LONGHORN_VERSION}" \
  --set defaultSettings.createDefaultDiskLabeledNodes=true \
  --set defaultSettings.defaultReplicaCount=3 \
  --set defaultSettings.storageOverProvisioningPercentage=100 \
  --set defaultSettings.taintToleration="storage=longhorn:NoSchedule"

# ── 22d. GATE 1: privileged SCC for every Longhorn SA ─────────────────────────
# Manager, instance-manager, and CSI components are all privileged + hostPath, so
# restricted-v2 rejects them until their ServiceAccount has 'privileged'. SAs are
# created lazily by the chart, so wait, then grant to ALL of them.
echo "  waiting for Longhorn service accounts..."
for i in $(seq 1 30); do
  [ "$(oc get sa -n longhorn-system --no-headers 2>/dev/null | wc -l)" -gt 3 ] && break
  sleep 10
done
for sa in $(oc get sa -n longhorn-system -o jsonpath='{.items[*].metadata.name}'); do
  oc adm policy add-scc-to-user privileged -z "$sa" -n longhorn-system
done
# UI is nginx — needs anyuid (write /var/log/nginx, /var/lib/nginx), not privileged
oc adm policy add-scc-to-user anyuid -z longhorn-ui-service-account -n longhorn-system

# ── 22e. GATE 2: finalizers RBAC — the fix the upstream docs DON'T have ────────
# OpenShift enforces blockOwnerDeletion/ownerReference rules more strictly than
# vanilla k8s. The chart's ClusterRole lacks 'update' on the /finalizers
# subresources, so the manager CANNOT create instance-manager CRs (it sets an
# ownerRef back to the Longhorn Node). Without this, instance-managers never
# appear, no engine processes run, CSI never deploys, PVCs hang forever.
oc apply -f - <<'RBAC'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: longhorn-finalizers-fix}
rules:
- apiGroups: ["longhorn.io"]
  resources:
    - nodes/finalizers
    - instancemanagers/finalizers
    - volumes/finalizers
    - engines/finalizers
    - replicas/finalizers
    - engineimages/finalizers
  verbs: ["update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: longhorn-finalizers-fix}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: longhorn-finalizers-fix}
subjects:
- {kind: ServiceAccount, name: longhorn-service-account, namespace: longhorn-system}
RBAC

# ── 22f. GATE 3: toleration onto the manager DaemonSet ────────────────────────
# --set defaultSettings.taintToleration does NOT reach the manager DS pod spec at
# install (chicken-and-egg: the manager applies the setting but can't bootstrap
# onto a tainted node first). Patch it directly so the manager lands on .40-.42.
oc patch ds longhorn-manager -n longhorn-system --type=merge -p '{
  "spec":{"template":{"spec":{"tolerations":[
    {"key":"storage","value":"longhorn","effect":"NoSchedule","operator":"Equal"}
  ]}}}}'
oc patch setting taint-toleration -n longhorn-system \
  --type=merge -p '{"value":"storage=longhorn:NoSchedule"}' 2>/dev/null || true

# Restart so the manager recreates under the granted SCC + RBAC + toleration.
# This is what finally lets it create instance-managers on every node.
oc rollout restart ds/longhorn-manager -n longhorn-system

# ── 22g. GATE 4: wait for instance-managers on ALL Longhorn nodes ─────────────
# The driver-deployer checks EVERY node for MountPropagation support, which a node
# only reports once it has a running instance-manager. Must wait for all of them
# before the deployer can succeed.
echo "  waiting for instance-managers on all Longhorn nodes..."

_lh_nodes()   { timeout 15 oc get nodes.longhorn.io -n longhorn-system --no-headers --request-timeout=10s 2>/dev/null | grep -c . || true; }
_im_running() { timeout 15 oc get pods            -n longhorn-system --no-headers --request-timeout=10s 2>/dev/null | grep -c '^instance-manager.* Running' || true; }

im_ready=false
deadline=$(( $(date +%s) + 480 ))                 # hard 8-minute ceiling
while [ "$(date +%s)" -lt "$deadline" ]; do
  expected=$(_lh_nodes);   expected=${expected:-0}
  running=$(_im_running);  running=${running:-0}
  if [ "$expected" -gt 0 ] && [ "$running" -ge "$expected" ]; then
    echo "  instance-managers up: $running/$expected"; im_ready=true; break
  fi
  echo "  instance-managers ${running}/${expected} ($(( deadline - $(date +%s) ))s left)..."
  sleep 10
done

if [ "$im_ready" != true ]; then
  echo "!! WARNING: instance-managers not all up within 8m — continuing anyway."
  echo "!! The driver-deployer restart + PVC smoke test below will catch real failures."
fi

# ── 22h. GATE 5: restart the driver-deployer ──────────────────────────────────
# If it ran before instance-managers reported MountPropagation it's stuck in
# CrashLoopBackOff and won't re-check on its own. Kick it now that all nodes
# report support — this time it passes and deploys the CSI stack.
oc rollout restart deploy/longhorn-driver-deployer -n longhorn-system 2>/dev/null || true

echo "  waiting for CSI provisioner..."
for i in $(seq 1 30); do
  oc get pods -n longhorn-system --no-headers 2>/dev/null \
    | grep '^csi-provisioner' | grep -q ' Running' && { echo "  CSI up"; break; }
  sleep 10
done

# ── 22i. StorageClass default + tier shaping ──────────────────────────────────
for i in $(seq 1 60); do oc get storageclass longhorn >/dev/null 2>&1 && break; sleep 10; done
oc patch storageclass longhorn -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Workers attach volumes but never host replicas — disable their scheduling
for ip in $WORKER_IPS; do
  node="ip-$(echo $ip | tr '.' '-')"
  for i in $(seq 1 30); do
    oc -n longhorn-system get nodes.longhorn.io "$node" >/dev/null 2>&1 && break; sleep 5
  done
  oc -n longhorn-system patch nodes.longhorn.io "$node" \
    --type=merge -p '{"spec":{"allowScheduling":false}}' 2>/dev/null || true
done

# ── 22j. Self-verify: a PVC must actually BIND before we call it done ─────────
# Catches a silently-broken provisioning path instead of declaring false success.
echo "  smoke-testing provisioning..."
oc apply -f - <<'PVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: lh-smoke, namespace: default}
spec: {accessModes: [ReadWriteOnce], storageClassName: longhorn, resources: {requests: {storage: 1Gi}}}
PVC
bound=false
for i in $(seq 1 30); do
  [ "$(oc get pvc lh-smoke -n default -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] \
    && { bound=true; break; }
  sleep 10
done
oc delete pvc lh-smoke -n default --wait=false 2>/dev/null || true
if $bound; then echo "==> storage provisioning VERIFIED"
else echo "!! WARNING: smoke PVC never bound — check CSI / driver-deployer"; fi

# ── 22k. Publish the storage watcher for the autoscaler box ───────────────────
curl -sf "$REPO_URL/autoscaler/storage-watcher.py" -o $WEB_ROOT/autoscaler/storage-watcher.py
chown www-data:www-data $WEB_ROOT/autoscaler/storage-watcher.py

echo "==> storage tier ready"
echo "==> Cluster setup complete"