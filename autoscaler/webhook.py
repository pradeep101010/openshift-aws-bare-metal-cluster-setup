#!/usr/bin/env python3
import subprocess, logging, os, time, base64
from flask import Flask, request, jsonify
from kubernetes import client, config

app = Flask(__name__)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

# ── Config from environment ───────────────────────────────────────────────────
KUBECONFIG          = os.environ.get('KUBECONFIG',          '/opt/autoscaler/kubeconfig')
CLUSTER_NAME        = os.environ.get('CLUSTER_NAME',        'ocp-poc')
BASTION_IP          = os.environ.get('BASTION_IP',          '')
BOOTSTRAP_IP        = os.environ.get('BOOTSTRAP_IP',        '')
BASE_DOMAIN         = os.environ.get('BASE_DOMAIN',         '')
UBUNTU_AMI          = os.environ.get('UBUNTU_AMI',          '')
NODE_INSTANCE_TYPE  = os.environ.get('NODE_INSTANCE_TYPE',  'm5.metal')
SUBNET_ID           = os.environ.get('SUBNET_ID',           '')
NODE_SG_ID          = os.environ.get('NODE_SG_ID',          '')
IAM_PROFILE         = os.environ.get('IAM_PROFILE',         '')
REGION              = os.environ.get('REGION',              'us-east-1')
AZ                  = os.environ.get('AZ',                  'us-east-1a')
MIN_WORKERS         = int(os.environ.get('MIN_WORKERS',     '2'))
MAX_WORKERS         = int(os.environ.get('MAX_WORKERS',     '10'))
BASE_WORKER_IP      = os.environ.get('BASE_WORKER_IP',      '10.0.1')
BASE_WORKER_OFFSET  = int(os.environ.get('BASE_WORKER_OFFSET', '24'))

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
        f"'Name=instance-state-name,Values=running' "
        f"--query 'Reservations[0].Instances[0].InstanceId' "
        f"--region {REGION} --output text"
    )
    return result.stdout.strip()

def get_node_userdata(index):
    with open("/opt/autoscaler/scripts/node-init.sh.tpl") as f:
        template = f.read()
    script = template \
        .replace("${bastion_ip}",   BASTION_IP) \
        .replace("${bootstrap_ip}", BOOTSTRAP_IP) \
        .replace("${role}",         "worker") \
        .replace("${cluster_name}", CLUSTER_NAME) \
        .replace("${base_domain}",  BASE_DOMAIN)
    return base64.b64encode(script.encode()).decode()

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
    """Update MachineSet status so ClusterAutoscaler sees reality and stops retrying"""
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
    """Wait until expected number of workers are Ready in cluster"""
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

# ── Scale up ──────────────────────────────────────────────────────────────────
def scale_up(desired):
    current   = get_worker_count()
    new_index = current
    new_ip    = f"{BASE_WORKER_IP}.{BASE_WORKER_OFFSET + new_index}"

    logging.info(f"==> Provisioning worker{new_index} at {new_ip}")

    # launch EC2 instance
    run(
        f"aws ec2 run-instances "
        f"--image-id {UBUNTU_AMI} "
        f"--instance-type {NODE_INSTANCE_TYPE} "
        f"--subnet-id {SUBNET_ID} "
        f"--private-ip-address {new_ip} "
        f"--iam-instance-profile Name={IAM_PROFILE} "
        f"--security-group-ids {NODE_SG_ID} "
        f"--placement AvailabilityZone={AZ} "
        f"--user-data '{get_node_userdata(new_index)}' "
        f"--tag-specifications "
        f"'ResourceType=instance,Tags=["
        f"{{Key=Name,Value={CLUSTER_NAME}-worker{new_index}}},"
        f"{{Key=OCPRole,Value=worker}}"
        f"]' "
        f"--region {REGION}"
    )

    # wait for instance to appear
    logging.info("Waiting for instance to start...")
    time.sleep(30)
    instance_id = get_instance_id_by_ip(new_ip)

    # create RHCOS EBS volume
    vol_result = run(
        f"aws ec2 create-volume "
        f"--availability-zone {AZ} "
        f"--size 130 "
        f"--volume-type gp3 "
        f"--tag-specifications "
        f"'ResourceType=volume,Tags=["
        f"{{Key=Name,Value={CLUSTER_NAME}-worker{new_index}-rhcos}},"
        f"{{Key=OCPRole,Value=worker}}"
        f"]' "
        f"--region {REGION} "
        f"--query VolumeId --output text"
    )
    vol_id = vol_result.stdout.strip()
    logging.info(f"Created RHCOS volume {vol_id}")

    # wait for volume to be available
    run(f"aws ec2 wait volume-available --volume-ids {vol_id} --region {REGION}")

    # attach RHCOS volume
    run(
        f"aws ec2 attach-volume "
        f"--volume-id {vol_id} "
        f"--instance-id {instance_id} "
        f"--device /dev/xvdf "
        f"--region {REGION}"
    )
    logging.info(f"Attached {vol_id} to {instance_id}")

    # update spec immediately so ClusterAutoscaler knows we're working on it
    update_machineset_replicas(desired)

    # wait for node to actually join then update status
    # this is what tells ClusterAutoscaler the scale succeeded
    if wait_for_node_ready(desired):
        update_machineset_status(desired)
    else:
        logging.error("Node never joined — ClusterAutoscaler will retry")

    logging.info(f"==> worker{new_index} provisioned and MachineSet fully updated")

# ── Scale down ────────────────────────────────────────────────────────────────
def scale_down(desired):
    last_worker = drain_last_worker()

    if last_worker:
        ip          = get_node_ip(last_worker)
        instance_id = get_instance_id_by_ip(ip)

        # get attached volumes before terminating
        vol_result = run(
            f"aws ec2 describe-instances --instance-id {instance_id} "
            f"--query 'Reservations[0].Instances[0].BlockDeviceMappings[*].Ebs.VolumeId' "
            f"--region {REGION} --output text"
        )
        vol_ids = vol_result.stdout.strip().split()

        # terminate instance
        run(
            f"aws ec2 terminate-instances "
            f"--instance-ids {instance_id} "
            f"--region {REGION}"
        )
        logging.info(f"Terminated {instance_id}")

        # wait for termination then delete volumes
        run(f"aws ec2 wait instance-terminated --instance-ids {instance_id} --region {REGION}")
        for vol in vol_ids:
            run(f"aws ec2 delete-volume --volume-id {vol} --region {REGION}")
            logging.info(f"Deleted volume {vol}")

        # remove node from cluster
        run(f"oc delete node {last_worker} --kubeconfig {KUBECONFIG}")

    # update both spec and status — node is already gone so immediate
    update_machineset_replicas(desired)
    update_machineset_status(desired)
    logging.info(f"==> Scale down complete, MachineSet fully updated to {desired}")

# ── Routes ────────────────────────────────────────────────────────────────────
@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "ok"})

@app.route('/scale', methods=['POST'])
def handle_scale():
    data    = request.json
    desired = data.get('desired')
    current = get_worker_count()

    logging.info(f"Scale request: desired={desired} current={current}")

    if desired is None:
        return jsonify({"error": "desired count required"}), 400

    desired = max(MIN_WORKERS, min(MAX_WORKERS, desired))

    if desired > current:
        logging.info(f"Scaling UP {current} → {desired}")
        scale_up(desired)
    elif desired < current:
        logging.info(f"Scaling DOWN {current} → {desired}")
        scale_down(desired)
    else:
        logging.info("No scaling needed")

    return jsonify({"status": "ok", "desired": desired, "previous": current})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)