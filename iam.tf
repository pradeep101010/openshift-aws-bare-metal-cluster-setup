resource "aws_iam_role" "ocp_node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ocp_node_ec2" {
  name = "${var.cluster_name}-node-ec2-policy"
  role = aws_iam_role.ocp_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Volume swap
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "ec2:DescribeInstanceStatus",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:ModifyInstanceAttribute",
        ]
        Resource = "*"
      },
      {
        # EBS CSI driver
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume",
          "ec2:DeleteVolume",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot",
          "ec2:DescribeSnapshots",
          "ec2:DescribeAvailabilityZones",
          "ec2:CreateTags",
        ]
        Resource = "*"
      },
      {
        # SSM for remote debugging
        Effect   = "Allow"
        Action   = ["ssm:*", "ssmmessages:*", "ec2messages:*"]
        Resource = "*"
      },
      {
        # Autoscaler VM — provision and terminate worker nodes
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:DescribeImages",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeTags",
          "iam:PassRole",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ocp_node" {
  name = "${var.cluster_name}-node-profile"
  role = aws_iam_role.ocp_node.name
  tags = local.common_tags
}