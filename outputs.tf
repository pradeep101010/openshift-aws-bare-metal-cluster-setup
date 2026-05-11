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

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    1. Wait ~10 min for bastion to finish setup:
       ssh ubuntu@${aws_instance.bastion.public_ip} 'tail -f /var/log/bastion-init.log'

    2. Once bastion shows 'BASTION READY', run the volume-swap script:
       ./complete-setup.sh ${aws_instance.bastion.public_ip} ${var.aws_region} ${var.cluster_name}

    3. Monitor bootstrap from bastion:
       ssh ubuntu@${aws_instance.bastion.public_ip}
       openshift-install wait-for bootstrap-complete --dir=~/ocp-install --log-level=info

    4. After bootstrap completes, approve worker CSRs:
       export KUBECONFIG=~/ocp-install/auth/kubeconfig
       oc get csr | grep Pending | awk '{print $1}' | xargs oc adm certificate approve

    5. Monitor install completion:
       openshift-install wait-for install-complete --dir=~/ocp-install --log-level=info
  EOT
}
