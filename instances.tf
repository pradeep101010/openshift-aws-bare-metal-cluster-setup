# ── RHCOS AMI ─────────────────────────────────────────────────────────────────
data "aws_ami" "rhcos" {
  most_recent = true
  owners      = ["531415883065"]  # Red Hat

  filter {
    name   = "name"
    values = ["rhcos-414.92*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── Key Pair ──────────────────────────────────────────────────────────────────
resource "aws_key_pair" "ocp" {
  key_name   = var.key_pair_name
  public_key = var.ssh_public_key
  tags       = local.common_tags
}

# ── Bastion (Ubuntu) ──────────────────────────────────────────────────────────
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.bastion_instance_type
  subnet_id                   = aws_subnet.ocp.id
  private_ip                  = local.bastion_ip
  key_name                    = aws_key_pair.ocp.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ocp_node.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/scripts/bastion-init-bootstrap.sh.tpl", {
    cluster_name         = var.cluster_name
    base_domain          = var.base_domain
    ocp_version          = var.ocp_version
    pull_secret          = var.pull_secret
    ssh_public_key       = local.ssh_public_key
    node_ssh_private_key = local.node_ssh_private_key
    bastion_ip           = local.bastion_ip
    bootstrap_ip         = local.bootstrap_ip
    master0_ip           = local.master_ips[0]
    master1_ip           = local.master_ips[1]
    master2_ip           = local.master_ips[2]
    worker_ips           = join(" ", local.worker_ips)
    subnet_cidr          = var.subnet_cidr
  }))

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-bastion" })
}

# ── Gate 1: wait for bastion to publish ignition files ───────────────────────
resource "null_resource" "wait_for_bastion" {
  depends_on = [aws_instance.bastion]

  triggers = {
    bastion_id = aws_instance.bastion.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for bastion to publish ignition files..."
      for i in $(seq 1 120); do
        if curl -sf --max-time 10 http://${aws_instance.bastion.public_ip}:8080/ignition/bootstrap.ign > /dev/null 2>&1; then
          echo "Bastion ready — ignition files available"
          exit 0
        fi
        echo "  attempt $i/120 — bastion not ready yet"
        sleep 15
      done
      echo "FATAL: bastion never came up"
      exit 1
    EOT
  }
}

# ── Autoscaler ────────────────────────────────────────────────────────────────
resource "aws_instance" "autoscaler" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.ocp.id
  private_ip                  = local.autoscaler_ip
  key_name                    = aws_key_pair.ocp.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ocp_node.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

user_data = base64encode(templatefile("${path.module}/scripts/autoscaler-init.sh.tpl", {
    bastion_ip          = local.bastion_ip
    cluster_name        = var.cluster_name
    node_instance_type  = var.worker_instance_type
    key_pair_name       = aws_key_pair.ocp.key_name
    rhcos_disk_size_gb  = var.rhcos_disk_size_gb
  }))

  depends_on = [aws_instance.bastion]
  tags       = merge(local.common_tags, { Name = "${var.cluster_name}-autoscaler" })
}

# ── Fixed OCP Nodes — Bootstrap + Masters (RHCOS direct) ──────────────────────
resource "aws_instance" "ocp_node" {
  for_each = local.fixed_nodes

  ami                         = data.aws_ami.rhcos.id
  instance_type               = var.master_instance_type
  availability_zone           = var.availability_zone
  subnet_id                   = aws_subnet.ocp.id
  key_name                    = aws_key_pair.ocp.key_name
  private_ip                  = each.value.ip
  vpc_security_group_ids      = [aws_security_group.ocp_nodes.id]
  iam_instance_profile        = aws_iam_instance_profile.ocp_node.name
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.rhcos_disk_size_gb
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/scripts/ignition-stub.json.tpl", {
    role       = each.value.role
    bastion_ip = local.bastion_ip
  })

  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"
  }

  depends_on = [null_resource.wait_for_bastion]

  tags = merge(local.common_tags, {
    Name    = "${var.cluster_name}-${each.key}"
    OCPRole = each.value.role
  })
}

# ── Gate 2: wait for masters to form cluster (bootstrap-complete) ────────────
resource "null_resource" "wait_for_bootstrap_complete" {
  depends_on = [aws_instance.ocp_node]

  triggers = {
    nodes = join(",", [for k, v in aws_instance.ocp_node : v.id])
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for bootstrap-complete on bastion (masters forming cluster)..."
      for i in $(seq 1 240); do
        if ssh -i ${var.node_ssh_private_key_path} \
            -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ubuntu@${aws_instance.bastion.public_ip} \
            "sudo grep -q 'bootstrap-complete' /var/log/bastion-init.log" 2>/dev/null; then
          echo "Bootstrap-complete — masters running, MCS available"
          exit 0
        fi
        echo "  attempt $i/240 — masters still forming cluster"
        sleep 30
      done
      echo "FATAL: bootstrap-complete never fired"
      exit 1
    EOT
  }
}

# ── Dynamic Worker Nodes (RHCOS direct) ───────────────────────────────────────
resource "aws_instance" "worker" {
  for_each = local.worker_nodes

  ami                         = data.aws_ami.rhcos.id
  instance_type               = var.worker_instance_type
  availability_zone           = var.availability_zone
  subnet_id                   = aws_subnet.ocp.id
  key_name                    = aws_key_pair.ocp.key_name
  private_ip                  = each.value.ip
  vpc_security_group_ids      = [aws_security_group.ocp_nodes.id]
  iam_instance_profile        = aws_iam_instance_profile.ocp_node.name
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.rhcos_disk_size_gb
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/scripts/ignition-stub.json.tpl", {
    role       = "worker"
    bastion_ip = local.bastion_ip
  })

  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"
  }

  depends_on = [null_resource.wait_for_bootstrap_complete]

  tags = merge(local.common_tags, {
    Name    = "${var.cluster_name}-${each.key}"
    OCPRole = "worker"
  })
}