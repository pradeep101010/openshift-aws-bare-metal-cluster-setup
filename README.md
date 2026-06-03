# OpenShift on AWS — bare-metal-style UPI cluster

Terraform that stands up a self-hosting OpenShift 4.14 cluster on plain AWS EC2 (`platform: none`), fronts it with a bastion that does its own DNS and load balancing, and grows and shrinks the worker pool with a custom pod-driven autoscaler — all without depending on a single managed AWS service like ELB or Route 53.

It's a complete, opinionated reference for running OpenShift the hard way: you provide the compute and network, ignition turns blank RHCOS machines into cluster members, and the cluster keeps itself running.

> ⚠️ **This is a proof-of-concept / learning build.** The bastion is a deliberate single point of failure (see [Notes & caveats](#notes--caveats)). Don't run it as-is for production without making DNS and load balancing redundant.

---

## What you get

- **One-command bring-up** — `terraform apply` provisions everything and self-gates through bootstrap in the right order.
- **No cloud-LB dependency** — HAProxy on the bastion fronts the Kubernetes API, the Machine Config Server, and the apps ingress, all with health checks.
- **Self-registering nodes** — RHCOS workers boot from an ignition stub, fetch their real config from the cluster, and a CSR-approver service waves them in automatically.
- **Custom autoscaler** — watches for genuinely-unschedulable pods, launches RHCOS workers on demand, drains and removes idle ones, and keeps the load balancer in sync after every scaling event.
- **Cloud-agnostic by design** — the load-balancing and DNS patterns port to any bare-metal-ish environment, not just AWS.

---

## Architecture

External clients ──► api   ─┐
App users        ──► *.apps─┤   ┌─────────────────┐         ┌──────────────┐
                            ├──►│    Bastion      │──6443─► │  Masters ×3  │
New nodes (boot) ──► :8080 ─┘   │  DNS · ignition │ 22623   │ API·MCS·etcd │
                                │  HAProxy LB     │──80/443┐└──────┬───────┘
                                │  csr-approver   │        │   direct (overlay)
                                └───────▲─────────┘        ▼  pods · etcd
                                        │ refresh      ┌────────────────┐
                                ┌───────┴─────────┐    │  Workers ×N    │
                                │  Autoscaler     │──► │ router·kubelet │
                                │ watcher+webhook │    └────────────────┘
                                └───────┬─────────┘
                                        └──► AWS EC2 API (launch / terminate)

---

## How it works

The whole cluster pulls itself up in a fixed sequence, gated by Terraform:

1. **Bastion boots** and configures DNS (`dnsmasq`), an ignition file server (Apache on `:8080`), and downloads the OpenShift tooling. It generates the ignition configs and publishes them.
2. **Terraform Gate 1** waits until the bastion is serving ignition.
3. **Bootstrap + masters boot**, fetch their ignition, and form a control plane. The bootstrap node temporarily acts as the API until the masters take over, then it's terminated.
4. **Bastion installs HAProxy**, then flips the `api`/`api-int` DNS records to point at itself. (Order matters — HAProxy must be listening before the flip, or the API wait hangs.)
5. **Terraform Gate 2** waits for `bootstrap-complete`.
6. **Workers boot**, fetch their config (stub from `:8080`, then full config from the Machine Config Server on `:22623` via the bastion), submit CSRs, and the `csr-approver` service approves them.
7. **Bastion finishes up** — marks masters unschedulable, moves the routers onto workers, applies the autoscaler manifests, and publishes the autoscaler payload.
8. **Autoscaler EC2 boots**, pulls its scripts and kubeconfig from the bastion, and starts watching.


---

## Repository layout

```
.
├── versions.tf                 # provider + Terraform version constraints
├── variables.tf                # input variables
├── locals.tf                   # IP layout, tags, derived names
├── network.tf                  # VPC, subnet, security groups
├── iam.tf                      # instance profile / roles
├── data.tf                     # RHCOS + Ubuntu AMI lookups
├── instances.tf                # bastion, autoscaler, masters, workers, gates
├── outputs.tf
├── terraform.tfvars.example
├── scripts/
│   ├── bastion-init-bootstrap.sh.tpl   # everything the bastion runs on boot
│   ├── autoscaler-init.sh.tpl          # autoscaler EC2 setup
│   ├── ignition-stub.json.tpl          # the tiny first-boot config every node gets
│   └── csr-approver.service            # auto-approves node CSRs
└── autoscaler/
    ├── watcher.py                      # decides when/how much to scale
    ├── webhook.py                      # launches/terminates nodes, refreshes HAProxy
    ├── requirements.txt
    ├── ocp-autoscaler.service          # systemd unit + tunables
    └── manifests/
        ├── machineset.yaml
        ├── cluster-autoscaler.yaml
        └── machine-autoscaler.yaml
```

---

## Prerequisites

- An AWS account and credentials with EC2, IAM, and VPC permissions
- [Terraform](https://developer.hashicorp.com/terraform/downloads)
- An OpenShift **pull secret** ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))
- An SSH key pair (you'll provide the public key; the private key is used for the bring-up gates)
- A base domain you control (or accept the example domain for internal-only use)

---

## Quick start

```bash
git clone https://github.com/pradeep101010/openshift-aws-bare-metal-cluster-setup.git
cd openshift-aws-bare-metal-cluster-setup

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum set pull_secret, ssh_public_key, base_domain

terraform init
terraform plan
terraform apply
```

`apply` returns once the masters are up, but **workers and the autoscaler finish asynchronously**. Watch progress and confirm:

```bash
# from the bastion (terraform output gives its public IP)
ssh -i <your-key>.pem ubuntu@<bastion-ip>
tail -f /var/log/bastion-init.log

oc get nodes          # expect 3 masters + your initial workers, all Ready
oc get co             # all ClusterOperators Available
```

> RHCOS nodes use the `core` user for SSH, not `ubuntu`.

---

## Configuration

Set in `terraform.tfvars`:

| Variable | Example | Notes |
|---|---|---|
| `cluster_name` | `ocp-poc` | also the DNS + tag prefix |
| `base_domain` | `example.com` | cluster domain is `<cluster_name>.<base_domain>` |
| `ocp_version` | `4.14.x` | must match an available RHCOS AMI |
| `subnet_cidr` | `10.0.1.0/24` | the machine network |
| `availability_zone` | `us-east-1a` | single-AZ POC layout |
| `bastion_instance_type` | `t3.medium` | bastion sizing |
| `master_instance_type` | `m5.xlarge` | control-plane sizing |
| `worker_instance_type` | `t3.medium` | worker sizing |
| `rhcos_disk_size_gb` | `130` | root volume per node |
| `key_pair_name` | `ocp-key` | EC2 key pair name |
| `ssh_public_key` | `ssh-ed25519 ...` | injected into nodes |
| `pull_secret` | `{...}` | Red Hat pull secret |

### Autoscaler tunables

Set as `Environment=` lines in `autoscaler/ocp-autoscaler.service`:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_WORKERS` | `2` | floor |
| `MAX_WORKERS` | `10` | ceiling |
| `WORKER_CAPACITY_MILLI` | `1900` | per-worker allocatable mCPU — **must match your instance type** |
| `POLL_INTERVAL` | `30` | seconds between checks |
| `PENDING_THRESHOLD` | `1` | pending pods that trigger scale-up |
| `UTILIZATION_THRESHOLD` | `0.5` | scale-down trigger |
| `UNNEEDED_TIME` | `600` | seconds of idle before removal |
| `SCALE_UP_COOLDOWN` / `SCALE_DOWN_COOLDOWN` | `300` | anti-flap |

---

## Operating the cluster

**Watch the autoscaler**

```bash
ssh -i <key>.pem ubuntu@<autoscaler-ip>
sudo journalctl -u ocp-autoscaler -f
```

**Trigger a scale manually** (bypasses the watcher)

```bash
curl -s -XPOST http://<autoscaler-ip>:8080/scale \
  -H 'Content-Type: application/json' -d '{"desired":4}'
```

**Smoke-test autoscaling** — deploy pods sized to fit one-per-node on your instance type (≈`1500m` CPU each on a `t3.medium`):

```bash
oc new-project autoscaler-test
oc create deployment hog --image=registry.k8s.io/pause:3.9 --replicas=8 -n autoscaler-test
oc set resources deployment hog -n autoscaler-test --requests=cpu=1500m,memory=2Gi
# watch it scale up, then:
oc delete deployment hog -n autoscaler-test   # watch it scale back down
```

**Inspect the load balancer**

```bash
# on the bastion
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | awk -F, '{print $1,$2,$18}' | column -t
sudo /usr/local/bin/refresh-haproxy.sh   # manually re-sync worker backends
```

---

## Notes & caveats

- **The bastion is a single point of failure.** API access, app ingress, node provisioning, and DNS all run through it. If it dies, existing pods and etcd keep working, but kubelets gradually lose the API and no new nodes can join. Make DNS + LB redundant before relying on this.
- **Apache runs on port 8080, not 80** — HAProxy owns 80 for app traffic. Every bastion HTTP reference (ignition stub, Terraform gates, autoscaler init, webhook callback) must use `:8080`.
- **HAProxy must front port 22623** (the Machine Config Server) or workers fetch their stub, then hang forever trying to get their full config. This is the easiest thing to forget.
- **`WORKER_CAPACITY_MILLI` must match the worker instance type.** The wrong value makes scale-up under-provision (e.g. an m5 value on a t3.medium adds one node when you need several).
- **Size pod requests to fit a node.** A pod requesting more CPU/memory than one worker has will stay `Pending` no matter how many nodes the autoscaler adds.
- **Small workers + OpenShift monitoring don't mix well.** On `t3.medium` the monitoring stack may run degraded; add workers or trim it. It doesn't affect application workloads.

---

## Teardown

```bash
terraform destroy
```

If the autoscaler launched workers outside Terraform's state, terminate them first so `destroy` isn't left with dangling instances:

```bash
aws ec2 describe-instances \
  --filters 'Name=tag:OCPRole,Values=worker' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].InstanceId' --region <region> --output text \
| xargs -r aws ec2 terminate-instances --region <region> --instance-ids
```

---
