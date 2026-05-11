# OpenShift 4.14 on AWS Bare Metal — Terraform

Deploys a full OpenShift 4.14 UPI cluster on AWS using `m5.metal` bare metal
instances with **zero manual intervention** after `terraform apply`.

Since AWS bare metal instances do not expose EFI PXE boot, this setup uses
**coreos-installer** running from Ubuntu user-data to write RHCOS to a
secondary EBS volume. The bastion then orchestrates an automated volume swap
so each instance boots into RHCOS.

---

## Architecture

```
                         VPC 10.0.0.0/16
                         Subnet 10.0.0.0/20
┌─────────────────────────────────────────────────────┐
│                                                     │
│  Bastion (t3.xlarge, Ubuntu)          10.0.1.10    │
│  ├── Apache      → serves RHCOS + ignition + tools │
│  ├── dnsmasq     → DNS for api.*, etcd-*, *.apps.* │
│  ├── openshift-install → generates ignition configs│
│  └── orchestrator → volume swap + CSR approval     │
│                                                     │
│  Bootstrap (m5.metal, RHCOS)          10.0.1.20    │
│  ├── etcd (temporary)                              │
│  ├── kube-apiserver (temporary)                    │
│  └── machine-config-server                         │
│                                                     │
│  Master0  (m5.metal, RHCOS)           10.0.1.21    │
│  Master1  (m5.metal, RHCOS)           10.0.1.22    │
│  Master2  (m5.metal, RHCOS)           10.0.1.23    │
│                                                     │
│  Worker0  (m5.metal, RHCOS)           10.0.1.24    │
│  Worker1  (m5.metal, RHCOS)           10.0.1.25    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## How it works end to end

```
terraform apply
  │
  ├── Bastion boots (Ubuntu)
  │     └── bastion-init.sh:
  │           1.  Fix DNS → 169.254.169.253 (before dnsmasq is up)
  │           2.  Install packages (apache2, dnsmasq, awscli)
  │           3.  Configure dnsmasq (api.*, etcd.*, *.apps.*)
  │           4.  Download openshift-install + oc + kubectl
  │           5.  Download RHCOS metal image (~1GB)
  │           6.  Download coreos-installer binary
  │           7.  Generate ignition configs (bootstrap/master/worker)
  │           8.  Serve everything via Apache on port 80
  │           9.  Signal /ready → nodes start polling
  │           10. Wait for all 6 nodes to complete coreos-installer
  │           11. Volume swap ALL nodes (stop → detach → attach → start)
  │           12. Wait for all nodes to boot RHCOS
  │           13. Run wait-for-bootstrap-complete
  │           14. Update DNS: api.* → master0 (bootstrap done)
  │           15. Approve worker CSRs (two rounds)
  │           16. Run wait-for-install-complete
  │           17. Print console URL + kubeadmin password
  │
  ├── Each node boots (Ubuntu, 20GB root + 130GB data volume)
  │     └── node-init.sh:
  │           1. Fix DNS → 169.254.169.253
  │           2. Add hostname to /etc/hosts
  │           3. Use IMDSv2 for instance metadata
  │           4. Wait for bastion /ready
  │           5. Fetch coreos-installer from bastion (not internet)
  │           6. Detect 130GB secondary disk (/dev/nvme1n1 or /dev/xvdf)
  │           7. Run coreos-installer → write RHCOS to data volume
  │           8. POST to bastion /status/<node> → "done"
  │           ← bastion takes over from here
  │
  └── Bastion orchestrates the rest
        └── volume swap → RHCOS boot → bootstrap → CSRs → install complete
```

---

## Why no PXE?

AWS EC2 instances (including bare metal m5.metal) do not expose a
network PXE boot option via EFI. Instead of PXE, each node:

1. Boots Ubuntu (already has network + OS)
2. Runs `coreos-installer` to write RHCOS to a secondary EBS volume
3. Bastion stops the instance, swaps the root volume to the RHCOS volume
4. Instance restarts into RHCOS

This achieves the same result as PXE without requiring network boot support.

---

## Why bastion does the volume swap (not the node itself)

The node needs to stop itself to swap volumes — but the AWS CLI on the
node runs as a foreground process. When the instance stops, the process
is killed before it can complete the swap.

The bastion stays running throughout and orchestrates the swap externally
via AWS API — no race condition.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.3 |
| AWS CLI | >= 2.x |
| AWS credentials | `aws configure` or IAM role |

**AWS vCPU limit** — m5.metal has 96 vCPUs. 6 nodes = 576 vCPUs.
Request an increase at EC2 → Limits → Running On-Demand Metal instances.

---

## Quick Start

```bash
# 1. Fill in your values
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

# 2. Deploy
terraform init
terraform plan
terraform apply

# 3. Monitor — that's it
BASTION=$(terraform output -raw bastion_public_ip)
ssh -i <key.pem> ubuntu@$BASTION 'tail -f /var/log/bastion-init.log'
```

The bastion log will show every step. When it prints:

```
OCP CLUSTER READY
Console: https://console-openshift-console.apps.ocp-poc.example.com
kubeadmin password: XXXXX-XXXXX-XXXXX-XXXXX
```

Your cluster is up. No other steps needed.

---

## DNS

All OCP DNS is served by dnsmasq on the bastion. The VPC DHCP options
set points all VPC instances to `10.0.1.10` for DNS.

| Record | During install | After bootstrap |
|--------|---------------|-----------------|
| `api.ocp-poc.example.com` | `10.0.1.20` (bootstrap) | `10.0.1.21` (master0) |
| `api-int.ocp-poc.example.com` | `10.0.1.20` (bootstrap) | `10.0.1.21` (master0) |
| `*.apps.ocp-poc.example.com` | `10.0.1.24` (worker0) | `10.0.1.24` (worker0) |
| `etcd-0.ocp-poc.example.com` | `10.0.1.21` (master0) | `10.0.1.21` (master0) |
| `etcd-1.ocp-poc.example.com` | `10.0.1.22` (master1) | `10.0.1.22` (master1) |
| `etcd-2.ocp-poc.example.com` | `10.0.1.23` (master2) | `10.0.1.23` (master2) |

The bastion automatically updates `api.*` from bootstrap to master0
after `bootstrap-complete` succeeds.

---

## Static IPs

| Node | IP | Role |
|------|----|------|
| Bastion | 10.0.1.10 | Infrastructure |
| Bootstrap | 10.0.1.20 | Temporary (destroyed after install) |
| Master 0 | 10.0.1.21 | Control plane + etcd |
| Master 1 | 10.0.1.22 | Control plane + etcd |
| Master 2 | 10.0.1.23 | Control plane + etcd |
| Worker 0 | 10.0.1.24 | Compute + ingress |
| Worker 1 | 10.0.1.25 | Compute |

---

## Cost

| Instance | Type | Cost/hr | Count | Total/hr |
|----------|------|---------|-------|----------|
| Bastion | t3.xlarge | $0.166 | 1 | $0.17 |
| Nodes | m5.metal | $4.608 | 6 | $27.65 |
| **Total** | | | | **~$27.82/hr** |

**~$668/day. Destroy when not in use:**

```bash
terraform destroy
```

---

## Troubleshooting

**Watch bastion progress:**
```bash
ssh ubuntu@<bastion_ip> 'tail -f /var/log/bastion-init.log'
```

**Node stuck waiting for bastion:**
```bash
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/ocp-node-init.log
```

**coreos-installer failed:**
```bash
# Check if bastion is serving files
curl http://10.0.1.10/ready
curl http://10.0.1.10/ignition/master.ign | head -c 50
ls /var/www/html/rhcos/
```

**Volume swap failed:**
```bash
# Check bastion log — swap runs from bastion now
ssh ubuntu@<bastion_ip> 'grep -i swap /var/log/bastion-init.log'
```

**Bootstrap API not starting:**
```bash
ssh -i <key.pem> core@10.0.1.20   # from bastion
sudo journalctl -b -u bootkube -f
sudo crictl ps -a
```

**API unreachable after bootstrap:**
```bash
# DNS may still point to bootstrap — update manually
sudo sed -i 's|/10.0.1.20|/10.0.1.21|g' /etc/dnsmasq.conf
sudo systemctl restart dnsmasq
curl -k https://api.ocp-poc.example.com:6443/healthz
```

**Workers not joining:**
```bash
# Approve CSRs — two rounds needed
export KUBECONFIG=/home/ubuntu/ocp-install/auth/kubeconfig
oc get csr | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
# Wait 60s then run again
```

**Workers not pingable after reboot:**
```bash
# Stop/start the worker instances to force network re-init
aws ec2 stop-instances --instance-ids <id> --region us-east-1
aws ec2 wait instance-stopped --instance-ids <id> --region us-east-1
aws ec2 start-instances --instance-ids <id> --region us-east-1
```

---

## File Structure

```
ocp-terraform/
├── main.tf                    Provider, Ubuntu AMI data source
├── variables.tf               All input variables
├── locals.tf                  Static IPs, node definitions
├── vpc.tf                     VPC, subnet, IGW, routes, DHCP options
├── security_groups.tf         Bastion + node security groups
├── iam.tf                     IAM role (EC2 + SSM permissions)
├── instances.tf               Bastion + 6 nodes + 6 RHCOS EBS volumes
├── outputs.tf                 IPs, URLs, SSH commands
├── terraform.tfvars.example   Example variable values
├── complete-setup.sh          Manual fallback monitoring script
└── scripts/
    ├── bastion-init.sh.tpl    Full automation: setup + swap + install
    └── node-init.sh.tpl       RHCOS install + notify bastion
```
