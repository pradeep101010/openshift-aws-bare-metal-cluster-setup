locals {
  # Static private IPs — all within 10.0.0.0/20
  bastion_ip   = "10.0.1.10"
  bootstrap_ip = "10.0.1.20"
  master_ips   = ["10.0.1.21", "10.0.1.22", "10.0.1.23"]
  worker_ips   = ["10.0.1.24", "10.0.1.25"]

  # Node definitions used to drive for_each loops
  nodes = {
    bootstrap = { ip = "10.0.1.20", role = "bootstrap", index = 0 }
    master0   = { ip = "10.0.1.21", role = "master",    index = 0 }
    master1   = { ip = "10.0.1.22", role = "master",    index = 1 }
    master2   = { ip = "10.0.1.23", role = "master",    index = 2 }
    worker0   = { ip = "10.0.1.24", role = "worker",    index = 0 }
    worker1   = { ip = "10.0.1.25", role = "worker",    index = 1 }
  }

  cluster_domain = "${var.cluster_name}.${var.base_domain}"

  common_tags = {
    Project     = var.cluster_name
    ManagedBy   = "terraform"
    Environment = "poc"
  }
}
