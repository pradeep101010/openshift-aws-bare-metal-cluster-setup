#!/usr/bin/env python3
from kubernetes import client, config, watch
import requests, logging, os, time

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)

KUBECONFIG   = os.environ.get('KUBECONFIG',   '/opt/autoscaler/kubeconfig')
WEBHOOK_URL  = os.environ.get('WEBHOOK_URL',  'http://localhost:8080/scale')
MIN_WORKERS  = int(os.environ.get('MIN_WORKERS', '2'))
MAX_WORKERS  = int(os.environ.get('MAX_WORKERS', '10'))

last_desired = None

def load_kube():
    config.load_kube_config(KUBECONFIG)

def watch_machinesets():
    global last_desired
    load_kube()
    crd = client.CustomObjectsApi()
    w   = watch.Watch()

    logging.info("==> Watching MachineSets in openshift-machine-api...")

    while True:
        try:
            for event in w.stream(
                crd.list_namespaced_custom_object,
                group="machine.openshift.io",
                version="v1beta1",
                namespace="openshift-machine-api",
                plural="machinesets",
                timeout_seconds=300
            ):
                event_type = event['type']
                machineset = event['object']
                name       = machineset['metadata']['name']

                if name != 'worker-autoscale':
                    continue

                desired = machineset['spec'].get('replicas', 0)
                current = machineset.get('status', {}).get('readyReplicas', 0)

                logging.info(f"{event_type} — {name} spec.replicas={desired} status.readyReplicas={current}")

                if event_type != 'MODIFIED':
                    continue
                if desired == last_desired:
                    logging.info(f"Ignoring — already sent desired={desired} to webhook")
                    continue
                if desired == current:
                    logging.info(f"Ignoring — spec={desired} already matches status={current}")
                    continue
                if not (MIN_WORKERS <= desired <= MAX_WORKERS):
                    logging.warning(f"Ignoring — desired={desired} out of bounds [{MIN_WORKERS},{MAX_WORKERS}]")
                    continue

                logging.info(f"==> Scale event: {current} → {desired}, calling webhook")
                last_desired = desired

                try:
                    resp = requests.post(
                        WEBHOOK_URL,
                        json={"desired": desired},
                        timeout=10
                    )
                    logging.info(f"Webhook response: {resp.json()}")
                except Exception as e:
                    logging.error(f"Webhook call failed: {e}")
                    last_desired = None  # reset so we retry

        except Exception as e:
            logging.error(f"Watch error: {e} — retrying in 30s")
            time.sleep(30)
            load_kube()

if __name__ == '__main__':
    time.sleep(5)
    watch_machinesets()