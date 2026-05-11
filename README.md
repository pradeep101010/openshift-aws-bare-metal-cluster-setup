# OpenShift 4.14 on AWS Bare Metal — Terraform

Deploys a full OpenShift 4.14 UPI cluster on AWS using `m5.metal` bare metal
instances. Since AWS bare metal instances do not expose EFI PXE boot, this
setup uses **coreos-installer** running from Ubuntu user-data to write RHCOS
directly to a secondary EBS volume, then performs an automated volume swap so
the instance boots into RHCOS.

## Architecture

```
                         VPC 10.0.0.0/16
                         Subnet 10.0.0.0/20
┌─────────────────────────────────────────────────────┐
│                                                     │
│  Bastion (t3.xlarge, Ubuntu)          10.0.1.10    │
│  ├── Apache      → serves RHCOS image + ignition   │
│  ├── dnsmasq     → DNS for api.*, etcd-*, *.apps.* │
│  └── openshift-install → generates ignition configs│
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

## How the RHCOS install works (no PXE required)

```
Terraform apply
  │
  ├── Bastion boots Ubuntu
  │     └── user-data: installs Apache, dnsmasq, downloads RHCOS,
  │                    generates ignition configs, signals /ready
  │
  ├── Each node boots Ubuntu (8 GB root + 130 GB data volume)
  │     └── user-data:
  │           1. Waits for bastion /ready
  │           2. Runs coreos-installer → writes RHCOS to /dev/nvme1n1
  │           3. Uses AWS CLI to:
  │                stop instance
  │                detach Ubuntu root volume
  │                attach RHCOS volume as /dev/xvda
  │                start instance
  │           4. Node reboots into RHCOS
  │
  └── RHCOS first boot
        └── Ignition runs → fetches config from bootstrap (api-int.*)
              → nodes join OCP cluster
```

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.3 |
| AWS CLI | >= 2.x |
| AWS credentials | `aws configure` |

AWS account limits — m5.metal instances require a vCPU limit increase.
Each m5.metal has 96 vCPUs, so 6 nodes = 576 vCPUs. Request an increase
at: **EC2 → Limits → Running On-Demand Metal instances**.

## Quick Start

```bash
# 1. Clone / copy this directory
cd ocp-terraform

# 2. Fill in your values
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars          # add pull_secret, ssh keys, etc.

# 3. Deploy infrastructure
terraform init
terraform plan
terraform apply               # takes ~15 min for all instances to launch

# 4. Monitor bastion setup (in another terminal)
BASTION=$(terraform output -raw bastion_public_ip)
ssh ubuntu@$BASTION 'tail -f /var/log/bastion-init.log'

# 5. Once bastion shows "BASTION READY", run the completion script
chmod +x complete-setup.sh
./complete-setup.sh $BASTION us-east-1 ocp-poc ~/.ssh/your-key.pem

# 6. SSH to bastion and monitor OCP bootstrap
ssh ubuntu@$BASTION
openshift-install wait-for bootstrap-complete \
  --dir=~/ocp-install --log-level=info

# 7. Approve worker CSRs (run twice — there are two rounds)
export KUBECONFIG=~/ocp-install/auth/kubeconfig
oc get csr | grep Pending | awk '{print $1}' | xargs oc adm certificate approve

# 8. Wait for full install
openshift-install wait-for install-complete \
  --dir=~/ocp-install --log-level=info
```

## DNS

All OCP DNS is served by **dnsmasq on the bastion**. The VPC DHCP options
set points all instances to `10.0.1.10` (bastion) for DNS. Records served:

| Record | Resolves To |
|--------|------------|
| `api.ocp-poc.example.com` | `10.0.1.20` (bootstrap) |
| `api-int.ocp-poc.example.com` | `10.0.1.20` (bootstrap) |
| `*.apps.ocp-poc.example.com` | `10.0.1.24` (worker0) |
| `etcd-0.ocp-poc.example.com` | `10.0.1.21` (master0) |
| `etcd-1.ocp-poc.example.com` | `10.0.1.22` (master1) |
| `etcd-2.ocp-poc.example.com` | `10.0.1.23` (master2) |

Unknown queries are forwarded to the AWS VPC DNS (`169.254.169.253`).

## Static IPs

| Node | IP |
|------|----|
| Bastion | 10.0.1.10 |
| Bootstrap | 10.0.1.20 |
| Master 0 | 10.0.1.21 |
| Master 1 | 10.0.1.22 |
| Master 2 | 10.0.1.23 |
| Worker 0 | 10.0.1.24 |
| Worker 1 | 10.0.1.25 |

## Cost Warning

`m5.metal` costs ~$4.61/hour per instance.
**6 nodes × $4.61 = ~$27.66/hour (~$663/day).**
Destroy the cluster when not in use:

```bash
terraform destroy
```

## Troubleshooting

**Bastion not ready after 15 min:**
```bash
ssh ubuntu@<bastion_ip> 'cat /var/log/bastion-init.log'
```

**Node stuck on coreos-installer:**
```bash
# Check node user-data log via SSM (no SSH needed)
aws ssm start-session --target <instance-id>
sudo cat /var/log/ocp-node-init.log
```

**Node booted back into Ubuntu instead of RHCOS:**
```bash
# Volume swap may have failed — check swap log
aws ssm start-session --target <instance-id>
sudo cat /var/log/ocp-volume-swap.log
```

**Bootstrap API not starting:**
```bash
ssh core@10.0.1.20  # from bastion
sudo journalctl -u bootkube -f
sudo crictl ps -a
```

**Masters can't join:**
```bash
# Verify DNS resolves on each master
ssh core@10.0.1.21   # from bastion
curl -k https://api-int.ocp-poc.example.com:22623/config/master
```

## File Structure

```
ocp-terraform/
├── main.tf                    Provider, AMI data source
├── variables.tf               Input variables
├── locals.tf                  Static IPs, node map
├── vpc.tf                     VPC, subnet, IGW, route table, DHCP options
├── security_groups.tf         Bastion + node security groups
├── iam.tf                     IAM role for node volume swap
├── instances.tf               Bastion, 6 nodes, 6 RHCOS EBS volumes
├── outputs.tf                 IPs, URLs, SSH commands, next steps
├── terraform.tfvars.example   Template for your variables
├── complete-setup.sh          Post-apply monitoring + completion script
└── scripts/
    ├── bastion-init.sh.tpl    Bastion setup (Apache, dnsmasq, ignition)
    └── node-init.sh.tpl       Node setup (coreos-installer + volume swap)
```
