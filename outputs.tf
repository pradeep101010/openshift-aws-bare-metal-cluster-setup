output "bastion_public_ip" {
  description = "SSH into bastion: ssh -i <key.pem> ubuntu@<ip>"
  value       = aws_instance.bastion.public_ip
}

output "bastion_private_ip" {
  value = aws_instance.bastion.private_ip
}

output "node_ips" {
  description = "Private IPs of all OCP nodes"
  value = {
    for k, v in aws_instance.ocp_node : k => {
      private_ip = v.private_ip
      public_ip  = v.public_ip
      role       = local.nodes[k].role
    }
  }
}

output "cluster_api_url" {
  description = "OCP API endpoint (resolves via bastion dnsmasq)"
  value       = "https://api.${var.cluster_name}.${var.base_domain}:6443"
}

output "cluster_console_url" {
  description = "OCP console URL (after install completes)"
  value       = "https://console-openshift-console.apps.${var.cluster_name}.${var.base_domain}"
}

output "ssh_commands" {
  description = "Useful SSH commands"
  value = {
    bastion   = "ssh -i <key.pem> ubuntu@${aws_instance.bastion.public_ip}"
    bootstrap = "ssh -i <key.pem> -J ubuntu@${aws_instance.bastion.public_ip} core@${local.bootstrap_ip}"
    master0   = "ssh -i <key.pem> -J ubuntu@${aws_instance.bastion.public_ip} core@${local.master_ips[0]}"
  }
}
