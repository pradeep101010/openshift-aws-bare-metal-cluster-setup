# storage-nodes.tf
locals {
  storage_base_offset = 40
  storage_nodes = {
    for i in range(var.storage_node_count) :
    "storage${i}" => { ip = "10.0.1.${local.storage_base_offset + i}" }
  }
  storage_ips = [for k, v in local.storage_nodes : v.ip]
}

resource "aws_instance" "storage" {
  for_each = local.storage_nodes

  ami                         = data.aws_ami.rhcos.id
  instance_type               = var.storage_instance_type
  availability_zone           = var.availability_zone
  subnet_id                   = aws_subnet.ocp.id
  key_name                    = aws_key_pair.ocp.key_name
  private_ip                  = each.value.ip
  vpc_security_group_ids      = [aws_security_group.ocp_nodes.id]
  iam_instance_profile        = aws_iam_instance_profile.ocp_node.name
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.storage_disk_gb
    delete_on_termination = true
  }

  # Same ignition as workers — the "storage" role is a post-join label, not an ignition role
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
    OCPRole = "storage"
  })
}

# Gate: wait until Longhorn reports healthy on the bastion before declaring done
resource "null_resource" "wait_for_storage_ready" {
  depends_on = [aws_instance.storage]
  triggers   = { nodes = join(",", [for k, v in aws_instance.storage : v.id]) }

  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 1 120); do
        if ssh -i ${var.node_ssh_private_key_path} -o StrictHostKeyChecking=no \
            ubuntu@${aws_instance.bastion.public_ip} \
            "sudo grep -q 'storage tier ready' /var/log/bastion-init.log" 2>/dev/null; then
          echo "storage tier ready"; exit 0
        fi
        echo "  attempt $i/120 — storage tier not ready"; sleep 30
      done
      echo "FATAL: storage tier never came up"; exit 1
    EOT
  }
}