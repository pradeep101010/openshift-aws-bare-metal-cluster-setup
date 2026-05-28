variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for all instances. m5.metal is not available in every AZ — verify first."
  type        = string
  default     = "us-east-1a"
}

variable "cluster_name" {
  description = "OCP cluster name (used in DNS, hostnames, resource tags)"
  type        = string
  default     = "ocp-poc"
}

variable "base_domain" {
  description = "Base domain for the cluster"
  type        = string
  default     = "example.com"
}
variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}
variable "ocp_version" {
  description = "OpenShift version to install"
  type        = string
  default     = "4.14.0"
}

variable "pull_secret" {
  default = "{\"auths\":{\"cloud.openshift.com\"..." 
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file. Used if ssh_public_key is not set."
  type        = string
  default     = "~/.ssh/openshift-poc-rhcos-node.pub"
}

variable "ssh_public_key" {
  description = "SSH public key string. If set, overrides ssh_public_key_path."
  type        = string
  default     = null                  # null = read from file instead
}

variable "node_ssh_private_key_path" {
  type        = string
  default = "/Users/pradeepsn/Downloads/openshift-poc-rhcos-node.pem"
}
locals {
  ssh_public_key = var.ssh_public_key != null ? var.ssh_public_key : file(pathexpand(var.ssh_public_key_path))
  node_ssh_private_key = file(pathexpand(var.node_ssh_private_key_path))
}

# ── Rest of variables ──────────────────────────────────────────

variable "key_pair_name" {
  description = "AWS EC2 Key Pair name for SSH access to the bastion"
  type        = string
  default     = "openshift-poc-rhcos-node"
}

variable "bastion_instance_type" {
  description = "Bastion instance type"
  type        = string
  default     = "t3.medium"
}

variable "node_instance_type" {
  description = "OCP node instance type. Must be bare metal."
  type        = string
  default     = "t3.medium"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "rhcos_disk_size_gb" {
  description = "Size in GB of the RHCOS data volume attached to each node"
  type        = number
  default     = 130
}