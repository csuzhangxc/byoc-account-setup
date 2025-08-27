
module "bastions" {
  source = "./modules/bastion"

  for_each = var.bastions

  bastion_name                    = "tidbbyoc-bastion-${var.tidbcloud_tenant_id}-${var.aws_region}-${each.key}"
  aws_region                      = var.aws_region
  eks_cluster_name                = each.value.eks_cluster_name
  subnet_id                       = each.value.subnet_id
  eks_cluster_access_policy       = var.eks_cluster_access_policy
  instance_ami_id                 = var.bastion_ami_id
  instance_type                   = var.bastion_type
  auth_key                        = each.value.auth_key
  cloudwatch_audit_enable         = var.cloudwatch_audit_enable
  cloudwatch_audit_retention_days = var.cloudwatch_audit_retention_days
  additional_tags                 = var.additional_tags
}
