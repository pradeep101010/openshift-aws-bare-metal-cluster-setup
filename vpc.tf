# ── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "ocp" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${var.cluster_name}-vpc" })
}

# ── Subnet (single public subnet for POC) ────────────────────────────────────
resource "aws_subnet" "ocp" {
  vpc_id                  = aws_vpc.ocp.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = merge(local.common_tags, { Name = "${var.cluster_name}-subnet" })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "ocp" {
  vpc_id = aws_vpc.ocp.id
  tags   = merge(local.common_tags, { Name = "${var.cluster_name}-igw" })
}

# ── Route Table ───────────────────────────────────────────────────────────────
resource "aws_route_table" "ocp" {
  vpc_id = aws_vpc.ocp.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ocp.id
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-rt" })
}

resource "aws_route_table_association" "ocp" {
  subnet_id      = aws_subnet.ocp.id
  route_table_id = aws_route_table.ocp.id
}

# ── Custom DHCP Options — point all VPC instances to bastion for DNS ──────────
# This ensures RHCOS nodes resolve api-int.<cluster>.<domain> on first boot
# via the dnsmasq instance running on the bastion.
resource "aws_vpc_dhcp_options" "ocp" {
  domain_name         = "ec2.internal"
  domain_name_servers = [local.bastion_ip]
  tags                = merge(local.common_tags, { Name = "${var.cluster_name}-dhcp-opts" })
}

resource "aws_vpc_dhcp_options_association" "ocp" {
  vpc_id          = aws_vpc.ocp.id
  dhcp_options_id = aws_vpc_dhcp_options.ocp.id
}
