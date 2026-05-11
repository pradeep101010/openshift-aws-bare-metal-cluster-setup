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

variable "ocp_version" {
  description = "OpenShift version to install"
  type        = string
  default     = "4.14.0"
}

variable "pull_secret" {
  description = "OCP pull secret JSON from https://console.redhat.com/openshift/install/pull-secret"
  type        = string
  sensitive   = true
  default     = "{\"auths\":{\"cloud.openshift.com\":{\"auth\":\"b3BlbnNoaWZ0LXJlbGVhc2UtZGV2K29jbV9hY2Nlc3NfZjA1N2YxNjQ3MzQ1NDA1Yzk4OTA0MDdjNGZkY2Y0NWY6QlUySkhWTTMxT1M2M1VHVVMxVUw5MktYTEg5UEczR1g4TEJJR0FFRFJSVlNDTUNMRDk5VUo1UEdMNUlKN0VXMw==\",\"email\":\"pradeepsn@presidio.com\"},\"quay.io\":{\"auth\":\"b3BlbnNoaWZ0LXJlbGVhc2UtZGV2K29jbV9hY2Nlc3NfZjA1N2YxNjQ3MzQ1NDA1Yzk4OTA0MDdjNGZkY2Y0NWY6QlUySkhWTTMxT1M2M1VHVVMxVUw5MktYTEg5UEczR1g4TEJJR0FFRFJSVlNDTUNMRDk5VUo1UEdMNUlKN0VXMw==\",\"email\":\"pradeepsn@presidio.com\"},\"registry.connect.redhat.com\":{\"auth\":\"fHVoYy1wb29sLWJiZjU3MDE3LTc0N2ItNGEwOC1iMmJkLWJhNmY3NTMxNjVmNTpleUpoYkdjaU9pSlNVelV4TWlKOS5leUp6ZFdJaU9pSTNOVFV5TXpobVl6WTFabUUwTkRNeFlqSTJabU5oTXpabE1qSmtabUZpTUNKOS5YMG16YWtZN2daNFZLbzZNSllqY1BSemQ4dDJ1S3dCQVNQS21jZzNVVHU1YXFYMlZtcHh2aWh1aFJta3Z0WVJueHo0MmZld3ZLRUZVbF9LZ3BndlhaejFSTHJWVHlHekJ2MFZTSVBtTmdyNHQ0YlVMUElkLXRrY0FIVS0zTjluTjlfM19MZnhuaE13R2lTWFZKWlpqUXpmbXdVSS0ybFQ0eG5mZXF5MlowaDBFOVZsWktiVTQ1UHZiNlRHNEx2TzNxZml5LWZmaGwtaUZrRkhYSXNCWVU1RkQ2TXFXMlJ4TTN0eERyaE9VaW9xUHZER0xvay1vU0lMY1FJZmdmNjhKRGQyLW9qYTItMk5QTzFVb1p4TS1xdzJBNzctUTY0YzVmUkpoSFoxU25mSGpSRzUzelVLS2I5NzVwWTI4WWVqUEQzeS1tWE12bVM2SGo3UWdHb09pSkg3bWR5QjJpME5BM1dKMnNtMVdPZGhjeWx5eUlvSXVHTEdrOUpaU0tFYmVKUlBwY19qWkRrY3F0ZWMwaTVCM29nUzFtbk1ZZVB1dkp4dmpobXl5cS1QNUUxZ2otSXNNRVZaSDZPREpfdk15U01Wc0tFQzBMbWxSZ1dhMkxtU2tsQjl2RFpvWEtIS3BLVVJyTmEyVXZ4Z3JYbEI3TDh4ZzNNOGZjQVhFLWdOdHVJQWFQOVdaTjc1NjFrTjJ3cEVIcjJYVEd4enp4SGg5bUhoWlNqZEJOeDdYeWtGc3ZLWDVENnY4UVdPN2ZOaWl2dHJpcU9sanhKYkRybHlCYUJpbWZ1SGxGSHFHQkpkQ3ljNV9JVkpJQ25GMnNVR011T3FMbVJiel9zU2dFc3ktZVhYZ1VrM1J5ZEREMXZHWHhucHZfOXJPNVNqU3NST0xuX25kOVd2bzJabw==\",\"email\":\"pradeepsn@presidio.com\"},\"registry.redhat.io\":{\"auth\":\"fHVoYy1wb29sLWJiZjU3MDE3LTc0N2ItNGEwOC1iMmJkLWJhNmY3NTMxNjVmNTpleUpoYkdjaU9pSlNVelV4TWlKOS5leUp6ZFdJaU9pSTNOVFV5TXpobVl6WTFabUUwTkRNeFlqSTJabU5oTXpabE1qSmtabUZpTUNKOS5YMG16YWtZN2daNFZLbzZNSllqY1BSemQ4dDJ1S3dCQVNQS21jZzNVVHU1YXFYMlZtcHh2aWh1aFJta3Z0WVJueHo0MmZld3ZLRUZVbF9LZ3BndlhaejFSTHJWVHlHekJ2MFZTSVBtTmdyNHQ0YlVMUElkLXRrY0FIVS0zTjluTjlfM19MZnhuaE13R2lTWFZKWlpqUXpmbXdVSS0ybFQ0eG5mZXF5MlowaDBFOVZsWktiVTQ1UHZiNlRHNEx2TzNxZml5LWZmaGwtaUZrRkhYSXNCWVU1RkQ2TXFXMlJ4TTN0eERyaE9VaW9xUHZER0xvay1vU0lMY1FJZmdmNjhKRGQyLW9qYTItMk5QTzFVb1p4TS1xdzJBNzctUTY0YzVmUkpoSFoxU25mSGpSRzUzelVLS2I5NzVwWTI4WWVqUEQzeS1tWE12bVM2SGo3UWdHb09pSkg3bWR5QjJpME5BM1dKMnNtMVdPZGhjeWx5eUlvSXVHTEdrOUpaU0tFYmVKUlBwY19qWkRrY3F0ZWMwaTVCM29nUzFtbk1ZZVB1dkp4dmpobXl5cS1QNUUxZ2otSXNNRVZaSDZPREpfdk15U01Wc0tFQzBMbWxSZ1dhMkxtU2tsQjl2RFpvWEtIS3BLVVJyTmEyVXZ4Z3JYbEI3TDh4ZzNNOGZjQVhFLWdOdHVJQWFQOVdaTjc1NjFrTjJ3cEVIcjJYVEd4enp4SGg5bUhoWlNqZEJOeDdYeWtGc3ZLWDVENnY4UVdPN2ZOaWl2dHJpcU9sanhKYkRybHlCYUJpbWZ1SGxGSHFHQkpkQ3ljNV9JVkpJQ25GMnNVR011T3FMbVJiel9zU2dFc3ktZVhYZ1VrM1J5ZEREMXZHWHhucHZfOXJPNVNqU3NST0xuX25kOVd2bzJabw==\",\"email\":\"pradeepsn@presidio.com\"}}}"
}

# ── SSH Key Handling ───────────────────────────────────────────
# Priority: explicit var > file at ssh_public_key_path
# Just keep your .pub file at ~/.ssh/ocp-key.pub and never touch this again

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

locals {
  ssh_public_key = var.ssh_public_key != null ? var.ssh_public_key : file(pathexpand(var.ssh_public_key_path))
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
  default     = "m5.metal"
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