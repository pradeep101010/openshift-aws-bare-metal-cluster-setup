# IAM role attached to every OCP node.
# Grants EC2 + SSM permissions so the node user-data script can
# stop itself, swap the root volume, and restart — all via AWS API.

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
        # Volume swap: stop self, detach/attach volumes, start self
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:ModifyInstanceAttribute",
        ]
        Resource = "*"
      },
      {
        # SSM for remote debugging if needed
        Effect   = "Allow"
        Action   = ["ssm:*", "ssmmessages:*", "ec2messages:*"]
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
