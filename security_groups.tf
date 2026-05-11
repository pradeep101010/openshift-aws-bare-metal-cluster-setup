# ── Bastion Security Group ────────────────────────────────────────────────────
resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Bastion: SSH from internet, all traffic within VPC"
  vpc_id      = aws_vpc.ocp.id

  # SSH from anywhere (restrict to your IP in production)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }

  # All traffic from within the VPC subnet
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.subnet_cidr]
    description = "All traffic from VPC subnet"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-bastion-sg" })
}

# ── OCP Nodes Security Group ──────────────────────────────────────────────────
resource "aws_security_group" "ocp_nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "OCP nodes: all traffic within VPC, outbound to internet"
  vpc_id      = aws_vpc.ocp.id

  # All traffic from within the VPC subnet (covers node-to-node + bastion)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.subnet_cidr]
    description = "All traffic from VPC subnet"
  }

  # Self-referencing rule so nodes can talk to each other via SG
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
    description = "All traffic from same SG"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-nodes-sg" })
}
