#!/usr/bin/env python3
"""
Pod-driven autoscaler watcher.

Watches Pending pods cluster-wide. When pods are unschedulable due to
insufficient resources, computes how many workers are needed based on
the total pending CPU request and scales up to that. When workers are
underutilized over a sustained window, scales down.

Calls webhook.py to do the actual provisioning.
"""
from kubernetes import client, config
import requests, logging, os, time, math

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

# ── Config from environment ───────────────────────────────────────────────────
KUBECONFIG       = os.environ.get('KUBECONFIG',       '/opt/autoscaler/kubeconfig')
WEBHOOK_URL      = os.environ.get('WEBHOOK_URL',      'http://localhost:8080/scale')
MIN_WORKERS      = int(os.environ.get('MIN_WORKERS', '2'))
MAX_WORKERS      = int(os.environ.get('MAX_WORKERS', '10'))

POLL_INTERVAL    = int(os.environ.get('POLL_INTERVAL', '30'))
PENDING_THRESHOLD = int(os.environ.get('PENDING_THRESHOLD', '1'))

UNNEEDED_TIME    = int(os.environ.get('UNNEEDED_TIME', '600'))
UTILIZATION_THRESHOLD = float(os.environ.get('UTILIZATION_THRESHOLD', '0.5'))

SCALE_UP_COOLDOWN   = int(os.environ.get('SCALE_UP_COOLDOWN',   '300'))
SCALE_DOWN_COOLDOWN = int(os.environ.get('SCALE_DOWN_COOLDOWN', '300'))

# Worker capacity hint used for batch scale-up sizing (millicores allocatable per worker)
WORKER_CAPACITY_MILLI = int(os.environ.get('WORKER_CAPACITY_MILLI', '95500'))  # m5.metal default

last_scale_up_at   = 0
last_scale_down_at = 0
unneeded_since     = {}  # node_name -> timestamp first observed underutilized

# ── Helpers ───────────────────────────────────────────────────────────────────
def load_kube():
    config.load_kube_config(KUBECONFIG)

def parse_cpu(cpu_str):
    """Parse a Kubernetes CPU string ('500m', '2', '0.5') to millicores (int)."""
    s = str(cpu_str).strip()
    if not s or s == '0':
        return 0
    if s.endswith('m'):
        try:
            return int(s[:-1])
        except ValueError:
            return 0
    try:
        return int(float(s) * 1000)
    except ValueError:
        return 0

def get_worker_nodes():
    """Return list of Ready worker nodes (excluding masters)."""
    v1 = client.CoreV1Api()
    nodes = v1.list_node(label_selector='node-role.kubernetes.io/worker').items
    return [
        n for n in nodes
        if 'node-role.kubernetes.io/master' not in (n.metadata.labels or {})
        and any(c.type == 'Ready' and c.status == 'True' for c in (n.status.conditions or []))
    ]

def get_unschedulable_pods():
    """Return list of Pending pods that are Unschedulable (capacity reason)."""
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces(field_selector='status.phase=Pending').items
    out = []
    for p in pods:
        for c in (p.status.conditions or []):
            if c.type == 'PodScheduled' and c.status == 'False' and c.reason == 'Unschedulable':
                out.append(p)
                break
    return out

def pod_total_cpu_milli(pod):
    """Sum CPU requests across all containers in a pod (millicores)."""
    total = 0
    for c in (pod.spec.containers or []):
        req = '0'
        if c.resources and c.resources.requests:
            req = c.resources.requests.get('cpu', '0')
        total += parse_cpu(req)
    return total

def get_node_utilization(node_name):
    """Approximate CPU utilization based on pod requests (not actual usage).
       Returns 0.0..1.0+. Excludes system namespaces (overhead doesn't count)."""
    v1 = client.CoreV1Api()
    node = v1.read_node(node_name)
    alloc_milli = parse_cpu(node.status.allocatable.get('cpu', '0'))
    if alloc_milli == 0:
        return 0.0

    pods = v1.list_pod_for_all_namespaces(
        field_selector=f'spec.nodeName={node_name},status.phase=Running'
    ).items
    total_req_milli = 0
    for p in pods:
        ns = p.metadata.namespace
        if ns.startswith('openshift-') or ns == 'kube-system':
            continue
        total_req_milli += pod_total_cpu_milli(p)

    return total_req_milli / alloc_milli

def call_webhook(desired):
    try:
        resp = requests.post(WEBHOOK_URL, json={'desired': desired}, timeout=1800)
        logging.info(f"Webhook response: {resp.status_code} {resp.json()}")
        return resp.status_code < 400
    except Exception as e:
        logging.error(f"Webhook call failed: {e}")
        return False

# ── Decision loop ─────────────────────────────────────────────────────────────
def decide_and_act():
    global last_scale_up_at, last_scale_down_at, unneeded_since
    now = time.time()

    workers = get_worker_nodes()
    current = len(workers)
    pending_pods = get_unschedulable_pods()
    pending_count = len(pending_pods)

    logging.info(f"State: workers={current} unschedulable_pods={pending_count}")

    # ── Scale-up ──────────────────────────────────────────────────────────────
    if pending_count >= PENDING_THRESHOLD:
        if current >= MAX_WORKERS:
            logging.info(f"Skip scale-up: at max ({current}/{MAX_WORKERS})")
            return

        if now - last_scale_up_at < SCALE_UP_COOLDOWN:
            wait = int(SCALE_UP_COOLDOWN - (now - last_scale_up_at))
            logging.info(f"Skip scale-up: cooldown ({wait}s remaining)")
            return

        # Compute how many workers are needed based on total pending CPU
        total_pending_milli = sum(pod_total_cpu_milli(p) for p in pending_pods)
        # ceiling division — we need enough workers to fit the requests
        workers_needed = math.ceil(total_pending_milli / WORKER_CAPACITY_MILLI)
        workers_needed = max(workers_needed, 1)  # always at least one more if pending exist

        desired = min(MAX_WORKERS, current + workers_needed)
        added   = desired - current

        logging.info(
            f"==> Scale UP: {pending_count} pending pods need "
            f"{total_pending_milli}m CPU total; "
            f"adding {added} workers ({current} → {desired}, capped at MAX={MAX_WORKERS})"
        )

        if call_webhook(desired):
            last_scale_up_at = now
        unneeded_since.clear()
        return

    # ── Scale-down ────────────────────────────────────────────────────────────
    if current <= MIN_WORKERS:
        unneeded_since.clear()
        return

    if now - last_scale_down_at < SCALE_DOWN_COOLDOWN:
        wait = int(SCALE_DOWN_COOLDOWN - (now - last_scale_down_at))
        logging.info(f"Workers={current}, but scale-down on cooldown ({wait}s remaining)")
        return

    candidate = None
    for node in workers:
        name = node.metadata.name
        util = get_node_utilization(name)
        logging.info(f"  {name}: utilization={util:.2f}")

        if util < UTILIZATION_THRESHOLD:
            if name not in unneeded_since:
                unneeded_since[name] = now
                logging.info(f"  {name}: newly-unneeded, tracking")
            elif now - unneeded_since[name] >= UNNEEDED_TIME:
                logging.info(f"  {name}: unneeded for {int(now - unneeded_since[name])}s — candidate for removal")
                candidate = name
                break
        else:
            unneeded_since.pop(name, None)

    if candidate:
        desired = current - 1
        logging.info(f"==> Scale DOWN: removing underutilized node → {current} → {desired}")
        if call_webhook(desired):
            last_scale_down_at = now
        unneeded_since.clear()

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    load_kube()
    logging.info("==> Pod-driven autoscaler watcher starting")
    logging.info(f"    MIN_WORKERS={MIN_WORKERS} MAX_WORKERS={MAX_WORKERS}")
    logging.info(f"    WORKER_CAPACITY_MILLI={WORKER_CAPACITY_MILLI}")
    logging.info(f"    POLL_INTERVAL={POLL_INTERVAL}s")
    logging.info(f"    PENDING_THRESHOLD={PENDING_THRESHOLD}")
    logging.info(f"    UNNEEDED_TIME={UNNEEDED_TIME}s UTILIZATION_THRESHOLD={UTILIZATION_THRESHOLD}")
    logging.info(f"    SCALE_UP_COOLDOWN={SCALE_UP_COOLDOWN}s SCALE_DOWN_COOLDOWN={SCALE_DOWN_COOLDOWN}s")

    while True:
        try:
            decide_and_act()
        except Exception as e:
            logging.error(f"Decision loop error: {e} — retrying in {POLL_INTERVAL}s")
            try:
                load_kube()
            except Exception:
                pass
        time.sleep(POLL_INTERVAL)

if __name__ == '__main__':
    time.sleep(5)
    main()