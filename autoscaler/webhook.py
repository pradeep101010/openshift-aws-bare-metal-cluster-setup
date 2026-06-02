#!/usr/bin/env python3
import subprocess, logging, os, time, tempfile
from flask import Flask, request, jsonify
from kubernetes import client, config
import threading

scale_lock = threading.Lock()

app = Flask(__name__)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

# ── Config from environment ───────────────────────────────────────────────────
KUBECONFIG          = os.environ.get('KUBECONFIG',          '/opt/autoscaler/kubeconfig')
CLUSTER_NAME        = os.environ.get('CLUSTER_NAME',        'ocp-poc')
BASTION_IP          = os.environ.get('BASTION_IP',          '')
RHCOS_AMI           = os.environ.get('RHCOS_AMI',           '')
KEY_PAIR_NAME       = os.environ.get('KEY_PAIR_NAME',       '')
RHCOS_DISK_SIZE_GB  = int(os.environ.get('RHCOS_DISK_SIZE_GB', '130'))
NODE_INSTANCE_TYPE  = os.environ.get('NODE_INSTANCE_TYPE',  't3.medium')
SUBNET_ID           = os.environ.get('SUBNET_ID',           '')
NODE_SG_ID          = os.environ.get('NODE_SG_ID',          '')
IAM_PROFILE         = os.environ.get('IAM_PROFILE',         '')
REGION              = os.environ.get('REGION',              'us-east-1')
AZ                  = os.environ.get('AZ',                  'us-east-1a')
MIN_WORKERS         = int(os.environ.get('MIN_WORKERS',     '2'))
MAX_WORKERS         = int(os.environ.get('MAX_WORKERS',     '10'))
BASE_WORKER_IP      = os.environ.get('BASE_WORKER_IP',      '10.0.1')
BASE_WORKER_OFFSET  = int(os.environ.get('BASE_WORKER_OFFSET', '24'))
BASTION_DNS_REFRESH_URL = os.environ.get('BASTION_DNS_REFRESH_URL', f'http://{BASTION_IP}:8080/cgi-bin/refresh-dns.sh')


STUB_TEMPLATE_PATH  = '/opt/autoscaler/scripts/ignition-stub.json.tpl'

# ── Helpers ───────────────────────────────────────────────────────────────────
def run(cmd, cwd=None):
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True, cwd=cwd
    )
    if result.stdout: logging.info(result.stdout.strip())
    if result.returncode != 0: logging.error(result.stderr.strip())
    return result

def get_kube_client():
    config.load_kube_config(KUBECONFIG)
    return client.CustomObjectsApi()

def get_worker_count():
    result = run(
        f"oc get nodes -l node-role.kubernetes.io/worker "
        f"--no-headers --kubeconfig {KUBECONFIG} 2>/dev/null | grep -c Ready || true"
    )
    try:
        return int(result.stdout.strip())
    except:
        return 0

def refresh_bastion_dns():
    try:
        import urllib.request
        with urllib.request.urlopen(BASTION_DNS_REFRESH_URL, timeout=30) as resp:
            logging.info(f"Bastion DNS refresh: {resp.read().decode()[:500]}")
    except Exception as e:
        logging.error(f"Bastion DNS refresh failed: {e}")

def get_node_ip(node_name):
    result = run(
        f"oc get node {node_name} "
        f"-o jsonpath='{{.status.addresses[?(@.type==\"InternalIP\")].address}}' "
        f"--kubeconfig {KUBECONFIG}"
    )
    return result.stdout.strip()

def get_instance_id_by_ip(ip):
    result = run(
        f"aws ec2 describe-instances "
        f"--filters 'Name=private-ip-address,Values={ip}' "
        f"'Name=instance-state-name,Values=running,pending' "
        f"--query 'Reservations[0].Instances[0].InstanceId' "
        f"--region {REGION} --output text"
    )
    return result.stdout.strip()

def find_used_worker_ips():
    """Return set of IPs already taken by running/pending worker EC2s.
       Used to find the next free IP when scaling — prevents collisions after
       scale-down/scale-up cycles."""
    result = run(
        f"aws ec2 describe-instances "
        f"--filters 'Name=tag:OCPRole,Values=worker' "
        f"'Name=instance-state-name,Values=running,pending,stopping,stopped' "
        f"--query 'Reservations[].Instances[].PrivateIpAddress' "
        f"--region {REGION} --output text"
    )
    return set(result.stdout.strip().split())

def pick_next_worker_slot():
    """Find the first free (index, ip) in our worker range."""
    used = find_used_worker_ips()
    for offset in range(0, MAX_WORKERS + 5):
        candidate_ip = f"{BASE_WORKER_IP}.{BASE_WORKER_OFFSET + offset}"
        if candidate_ip not in used:
            return offset, candidate_ip
    raise RuntimeError("No free worker IP available in range")

def render_ignition_stub(role='worker'):
    """Render the ignition stub for a new RHCOS worker — same template the
       Terraform-launched initial workers use."""
    with open(STUB_TEMPLATE_PATH) as f:
        template = f.read()
    return template.replace('${bastion_ip}', BASTION_IP) \
                   .replace('${role}',       role)

def update_machineset_replicas(count):
    crd = get_kube_client()
    crd.patch_namespaced_custom_object(
        group="machine.openshift.io",
        version="v1beta1",
        namespace="openshift-machine-api",
        plural="machinesets",
        name="worker-autoscale",
        body={"spec": {"replicas": count}}
    )
    logging.info(f"MachineSet spec.replicas updated to {count}")

def update_machineset_status(ready_count):
    """Update MachineSet status field to reflect reality."""
    crd = get_kube_client()
    crd.patch_namespaced_custom_object_status(
        group="machine.openshift.io",
        version="v1beta1",
        namespace="openshift-machine-api",
        plural="machinesets",
        name="worker-autoscale",
        body={
            "status": {
                "replicas":          ready_count,
                "readyReplicas":     ready_count,
                "availableReplicas": ready_count,
            }
        }
    )
    logging.info(f"MachineSet status updated: readyReplicas={ready_count}")

def wait_for_node_ready(expected_count, timeout=1800):
    """Wait until expected number of workers are Ready in cluster."""
    logging.info(f"Waiting for {expected_count} workers to be Ready...")
    start = time.time()
    while time.time() - start < timeout:
        current = get_worker_count()
        logging.info(f"  {current}/{expected_count} workers Ready...")
        if current >= expected_count:
            logging.info(f"==> {current} workers Ready")
            return True
        time.sleep(30)
    logging.error(f"Timeout waiting for {expected_count} workers")
    return False

def drain_last_worker():
    """Drain and return the name of the most recently created worker."""
    result = run(
        f"oc get nodes -l node-role.kubernetes.io/worker "
        f"--no-headers --sort-by=.metadata.creationTimestamp "
        f"--kubeconfig {KUBECONFIG}"
    )
    lines = [l for l in result.stdout.strip().split('\n') if l]
    if not lines:
        logging.warning("No workers found to drain")
        return None
    last_worker = lines[-1].split()[0]
    logging.info(f"Draining {last_worker}")
    run(f"oc adm cordon {last_worker} --kubeconfig {KUBECONFIG}")
    run(
        f"oc adm drain {last_worker} "
        f"--ignore-daemonsets --delete-emptydir-data --force "
        f"--kubeconfig {KUBECONFIG}"
    )
    return last_worker

def sync_router_replicas():
    worker_count = get_worker_count()
    run(
        f"oc patch ingresscontroller default -n openshift-ingress-operator "
        f"--type=merge -p '{{\"spec\":{{\"replicas\":{worker_count}}}}}' "
        f"--kubeconfig {KUBECONFIG}"
    )
    logging.info(f"IngressController replicas set to {worker_count}")

def wait_for_routers_ready(timeout=300):
    start = time.time()
    while time.time() - start < timeout:
        result = run(
            f"oc get deploy router-default -n openshift-ingress "
            f"-o jsonpath='{{.status.availableReplicas}}/{{.spec.replicas}}' "
            f"--kubeconfig {KUBECONFIG}"
        )
        avail, _, want = result.stdout.strip().partition('/')
        if avail and want and avail == want and int(want) > 0:
            logging.info(f"==> routers ready: {avail}/{want}")
            return True
        time.sleep(10)
    logging.warning("routers did not all become ready in time")
    return False

# ── Provision one worker (called by scale_up loop) ────────────────────────────
def provision_one_worker():
    """Launch a single RHCOS worker. Returns the new IP on success, None on failure."""
    new_index, new_ip = pick_next_worker_slot()
    logging.info(f"==> Provisioning worker at index={new_index} ip={new_ip}")

    # Render ignition stub to a temp file — passed via --user-data file://
    stub = render_ignition_stub(role='worker')
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        f.write(stub)
        stub_path = f.name

    result = run(
        f"aws ec2 run-instances "
        f"--image-id {RHCOS_AMI} "
        f"--instance-type {NODE_INSTANCE_TYPE} "
        f"--subnet-id {SUBNET_ID} "
        f"--private-ip-address {new_ip} "
        f"--iam-instance-profile Name={IAM_PROFILE} "
        f"--security-group-ids {NODE_SG_ID} "
        f"--placement AvailabilityZone={AZ} "
        f"--key-name {KEY_PAIR_NAME} "
        f"--associate-public-ip-address "
        f"--metadata-options "
        f"'HttpEndpoint=enabled,HttpTokens=required,InstanceMetadataTags=enabled' "
        f"--block-device-mappings "
        f"'[{{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{{"
        f"\"VolumeType\":\"gp3\",\"VolumeSize\":{RHCOS_DISK_SIZE_GB},"
        f"\"DeleteOnTermination\":true}}}}]' "
        f"--user-data file://{stub_path} "
        f"--tag-specifications "
        f"'ResourceType=instance,Tags=["
        f"{{Key=Name,Value={CLUSTER_NAME}-worker{new_index}}},"
        f"{{Key=OCPRole,Value=worker}}"
        f"]' "
        f"--region {REGION}"
    )

    try:
        os.unlink(stub_path)
    except OSError:
        pass

    if result.returncode != 0:
        logging.error(f"run-instances failed for worker{new_index}")
        return None

    time.sleep(15)
    instance_id = get_instance_id_by_ip(new_ip)
    logging.info(f"  worker{new_index}: instance {instance_id} launched at {new_ip}")
    return new_ip

# ── Scale up ──────────────────────────────────────────────────────────────────
def scale_up(desired):
    """Launch as many workers as needed to reach `desired`.
       Each launch is sequential; we wait for ALL of them to be Ready at the end."""
    current = get_worker_count()
    to_add = desired - current
    logging.info(f"==> scale_up: adding {to_add} workers ({current} → {desired})")

    # Patch spec.replicas up-front so watchers see the target
    update_machineset_replicas(desired)

    launched = 0
    for i in range(to_add):
        if provision_one_worker() is not None:
            launched += 1
        else:
            logging.error(f"  failed to launch worker {i+1}/{to_add} — continuing with remaining")

    if launched == 0:
        logging.error("scale_up: no workers launched successfully")
        return

    logging.info(f"==> Launched {launched}/{to_add} workers; waiting for join")

    # Wait for all to join — desired is current + launched (in case some failed)
    expected = current + launched
    if wait_for_node_ready(expected):
        sync_router_replicas() 
        wait_for_routers_ready() 
        refresh_bastion_dns() 
        update_machineset_status(expected)
        logging.info(f"==> scale_up complete: {expected} workers ready")
    else:
        logging.error(f"==> scale_up timed out: only some workers joined")
        update_machineset_status(get_worker_count())
    

# ── Scale down ────────────────────────────────────────────────────────────────
def scale_down(desired):
    """Drain and terminate workers one at a time until current matches desired."""
    current = get_worker_count()
    to_remove = current - desired
    logging.info(f"==> scale_down: removing {to_remove} workers ({current} → {desired})")

    removed = 0
    for i in range(to_remove):
        last_worker = drain_last_worker()
        if not last_worker:
            logging.warning("  no workers left to remove")
            break

        ip          = get_node_ip(last_worker)
        instance_id = get_instance_id_by_ip(ip)

        if instance_id and instance_id != 'None':
            # Root volume has DeleteOnTermination=true — AWS cleans it up
            run(
                f"aws ec2 terminate-instances "
                f"--instance-ids {instance_id} "
                f"--region {REGION}"
            )
            logging.info(f"  Terminated {instance_id} ({last_worker})")
            run(f"aws ec2 wait instance-terminated --instance-ids {instance_id} --region {REGION}")
        else:
            logging.warning(f"  Could not find EC2 for {last_worker} — proceeding to delete Node only")

        # Remove node object from cluster
        run(f"oc delete node {last_worker} --kubeconfig {KUBECONFIG}")
        removed += 1
        logging.info(f"  Removed {last_worker} ({removed}/{to_remove})")

    final = current - removed
    update_machineset_replicas(final)
    update_machineset_status(final)
    sync_router_replicas() 
    wait_for_routers_ready() 
    refresh_bastion_dns() 
    logging.info(f"==> scale_down complete: removed {removed} workers, now at {final}")

# ── Routes ────────────────────────────────────────────────────────────────────
@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "ok"})

@app.route('/scale', methods=['POST'])
def handle_scale():
    data    = request.json or {}
    desired = data.get('desired')
    if desired is None:
        return jsonify({"error": "desired count required"}), 400

    # Only one scale operation at a time. If another is running, reject fast.
    if not scale_lock.acquire(blocking=False):
        logging.warning("Scale already in progress — rejecting concurrent request")
        return jsonify({"status": "busy", "message": "scale operation in progress"}), 409

    try:
        current = get_worker_count()
        logging.info(f"Scale request: desired={desired} current={current}")
        desired = max(MIN_WORKERS, min(MAX_WORKERS, desired))

        if desired > current:
            logging.info(f"Scaling UP {current} → {desired}")
            scale_up(desired)
        elif desired < current:
            logging.info(f"Scaling DOWN {current} → {desired}")
            scale_down(desired)
        else:
            logging.info("No scaling needed")

        final = get_worker_count()
        return jsonify({"status": "ok", "desired": desired, "previous": current, "current": final})
    finally:
        scale_lock.release()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)