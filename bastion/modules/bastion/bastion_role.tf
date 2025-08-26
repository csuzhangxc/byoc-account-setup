resource "aws_iam_role" "bastion_role" {
  name               = var.bastion_name
  description        = "Role for bastion host"
  assume_role_policy = file("./files/bastion_role_assume_policy.json")

  tags = var.additional_tags
}

resource "aws_iam_policy" "bastion_role_policy" {
  name        = var.bastion_name
  description = "Policy for bastion host"
  policy = templatefile("./files/bastion_role_policy.tftpl", {
    eks_cluster_arn = data.aws_eks_cluster.eks_cluster.arn
  })

  tags = var.additional_tags
}

resource "aws_iam_role_policy_attachment" "bastion_role_policy_attachment" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = aws_iam_policy.bastion_role_policy.arn
}

resource "aws_iam_role_policy_attachment" "bastion_role_policy_ssm_attachment" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "bastion_role_policy_cwagent_attachment" {
  count      = var.cloudwatch_audit_enable ? 1 : 0
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = var.bastion_name
  role = aws_iam_role.bastion_role.name

  tags = var.additional_tags
}
