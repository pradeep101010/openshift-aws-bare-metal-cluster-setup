locals {
  bastion_ip    = "10.0.1.10"
  bootstrap_ip  = "10.0.1.20"
  autoscaler_ip = "10.0.1.15"
  master_ips    = ["10.0.1.21", "10.0.1.22", "10.0.1.23"]

  # dynamic — grows with var.worker_count
  worker_ips = [
    for i in range(var.worker_count) : cidrhost("10.0.1.0/24", 24 + i)
  ]

  # bootstrap + masters — fixed forever
  fixed_nodes = {
    bootstrap = { ip = local.bootstrap_ip,  role = "bootstrap", index = 0 }
    master0   = { ip = local.master_ips[0], role = "master",    index = 0 }
    master1   = { ip = local.master_ips[1], role = "master",    index = 1 }
    master2   = { ip = local.master_ips[2], role = "master",    index = 2 }
  }

  # workers — driven by var.worker_count
  worker_nodes = {
    for i in range(var.worker_count) :
    "worker${i}" => {
      ip    = local.worker_ips[i]
      role  = "worker"
      index = i
    }
  }

  cluster_domain = "${var.cluster_name}.${var.base_domain}"

  common_tags = {
    Project     = var.cluster_name
    ManagedBy   = "terraform"
    Environment = "poc"
  }
}