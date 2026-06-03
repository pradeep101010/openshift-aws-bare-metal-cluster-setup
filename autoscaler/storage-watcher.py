#!/usr/bin/env python3
"""Storage-pool watcher: scales the Longhorn storage node pool on real disk usage."""
from kubernetes import client, config
import requests, logging, os, time

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

KUBECONFIG    = os.environ.get('KUBECONFIG', '/opt/autoscaler/kubeconfig')
WEBHOOK_URL   = os.environ.get('STORAGE_WEBHOOK_URL', 'http://localhost:8080/scale-storage')
STORAGE_MIN   = int(os.environ.get('STORAGE_MIN', '3'))
STORAGE_MAX   = int(os.environ.get('STORAGE_MAX', '8'))
POLL          = int(os.environ.get('STORAGE_POLL_INTERVAL', '60'))
UP_PCT        = float(os.environ.get('STORAGE_UP_THRESHOLD', '0.80'))
DOWN_PCT      = float(os.environ.get('STORAGE_DOWN_THRESHOLD', '0.50'))
UP_COOLDOWN   = int(os.environ.get('STORAGE_UP_COOLDOWN', '300'))
DOWN_COOLDOWN = int(os.environ.get('STORAGE_DOWN_COOLDOWN', '600'))
LH_NS, LH_GROUP, LH_VER = (os.environ.get('LONGHORN_NS', 'longhorn-system'),
                           'longhorn.io', os.environ.get('LONGHORN_VERSION', 'v1beta2'))
last_up = last_down = 0

def load_kube(): config.load_kube_config(KUBECONFIG)

def pool_usage():
    """(used_bytes, total_bytes, storage_node_count) from Longhorn Node CRs."""
    crd = client.CustomObjectsApi()
    nodes = crd.list_namespaced_custom_object(
        group=LH_GROUP, version=LH_VER, namespace=LH_NS, plural="nodes").get("items", [])
    total = used = count = 0
    for n in nodes:
        disks = (n.get("status") or {}).get("diskStatus") or {}
        has_disk = False
        for d in disks.values():
            mx, av = d.get("storageMaximum", 0) or 0, d.get("storageAvailable", 0) or 0
            if mx > 0:
                total += mx; used += (mx - av); has_disk = True
        if has_disk: count += 1
    return used, total, count

def call_webhook(desired):
    try:
        r = requests.post(WEBHOOK_URL, json={'desired': desired}, timeout=3600)
        logging.info(f"Webhook: {r.status_code} {r.json()}"); return r.status_code < 400
    except Exception as e:
        logging.error(f"Webhook failed: {e}"); return False

def decide():
    global last_up, last_down
    now = time.time()
    used, total, count = pool_usage()
    if total == 0:
        logging.info("No Longhorn disks reporting yet"); return
    pct = used / total
    logging.info(f"Storage pool: {pct:.0%} used across {count} nodes")

    if pct >= UP_PCT and count < STORAGE_MAX and now - last_up >= UP_COOLDOWN:
        logging.info(f"==> scale UP ({pct:.0%} >= {UP_PCT:.0%})")
        if call_webhook(count + 1): last_up = now
        return

    if count > STORAGE_MIN and now - last_down >= DOWN_COOLDOWN:
        per_node = total / count
        after = used / (total - per_node) if (total - per_node) > 0 else 1.0
        # only remove if usage stays under the down threshold after losing a node
        if pct <= DOWN_PCT and after <= DOWN_PCT:
            logging.info(f"==> scale DOWN ({pct:.0%} now, {after:.0%} after removal)")
            if call_webhook(count - 1): last_down = now

def main():
    load_kube()
    logging.info(f"==> Storage watcher: MIN={STORAGE_MIN} MAX={STORAGE_MAX} "
                 f"up={UP_PCT:.0%} down={DOWN_PCT:.0%}")
    while True:
        try: decide()
        except Exception as e:
            logging.error(f"loop error: {e}")
            try: load_kube()
            except Exception: pass
        time.sleep(POLL)

if __name__ == '__main__':
    time.sleep(10); main()