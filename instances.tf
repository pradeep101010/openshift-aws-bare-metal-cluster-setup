# ── Key Pair ──────────────────────────────────────────────────────────────────
resource "aws_key_pair" "ocp" {
  key_name   = var.key_pair_name
  public_key = var.ssh_public_key
  tags       = local.common_tags
}

# ── Bastion ───────────────────────────────────────────────────────────────────
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.bastion_instance_type
  subnet_id                   = aws_subnet.ocp.id
  private_ip                  = local.bastion_ip
  key_name                    = aws_key_pair.ocp.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  # IAM role so bastion can run AWS CLI without credentials
  # needed for volume swap orchestration
  iam_instance_profile        = aws_iam_instance_profile.ocp_node.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/scripts/bastion-init.sh.tpl", {
    cluster_name   = var.cluster_name
    base_domain    = var.base_domain
    ocp_version    = var.ocp_version
    pull_secret    = var.pull_secret
    ssh_public_key = var.ssh_public_key
    bastion_ip     = local.bastion_ip
    bootstrap_ip   = local.bootstrap_ip
    master0_ip     = local.master_ips[0]
    master1_ip     = local.master_ips[1]
    master2_ip     = local.master_ips[2]
    worker0_ip     = local.worker_ips[0]
    worker1_ip     = local.worker_ips[1]
    subnet_cidr    = var.subnet_cidr
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-bastion" })
}

# ── OCP Nodes (Ubuntu root 8 GB + RHCOS data 130 GB) ─────────────────────────
resource "aws_instance" "ocp_node" {
  for_each = local.nodes

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.node_instance_type
  availability_zone           = var.availability_zone
  subnet_id                   = aws_subnet.ocp.id
  private_ip                  = each.value.ip
  vpc_security_group_ids      = [aws_security_group.ocp_nodes.id]
  iam_instance_profile        = aws_iam_instance_profile.ocp_node.name
  associate_public_ip_address = true

  # Small Ubuntu root — will be detached after RHCOS install
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/scripts/node-init.sh.tpl", {
    bastion_ip     = local.bastion_ip
    bootstrap_ip   = local.bootstrap_ip
    role           = each.value.role
    cluster_name   = var.cluster_name
    base_domain    = var.base_domain
  }))

  # Ensure bastion is up first so its HTTP server is ready
  depends_on = [aws_instance.bastion]

  tags = merge(local.common_tags, {
    Name    = "${var.cluster_name}-${each.key}"
    OCPRole = each.value.role
  })
}

# ── RHCOS Data Volumes (130 GB each) ─────────────────────────────────────────
resource "aws_ebs_volume" "rhcos" {
  for_each = local.nodes

  availability_zone = var.availability_zone
  size              = var.rhcos_disk_size_gb
  type              = "gp3"

  tags = merge(local.common_tags, {
    Name    = "${var.cluster_name}-${each.key}-rhcos"
    OCPRole = each.value.role
  })
}

resource "aws_volume_attachment" "rhcos" {
  for_each = local.nodes

  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.rhcos[each.key].id
  instance_id  = aws_instance.ocp_node[each.key].id
  force_detach = true
}
