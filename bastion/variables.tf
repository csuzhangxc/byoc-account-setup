variable "aws_region" {
  description = "AWS region where the tidbcloud cluster is located"
  type        = string
}

variable "tidbcloud_tenant_id" {
  description = "TiDBCloud tenant ID"
  type        = string
}

variable "bastions" {
  description = "List of bastion host configurations"
  type = map(object({
    eks_cluster_name = string
    auth_key         = string
    subnet_id        = optional(string, "")
  }))
}

variable "bastion_ami_id" {
  description = "The AMI ID to use for the bastion host"
  type        = string
  default     = ""
}

variable "bastion_type" {
  description = "The instance type for the bastion host"
  type        = string
  default     = "t3.micro"
}

variable "eks_cluster_access_policy" {
  description = "The access policy for the EKS cluster access, see https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html"
  type        = string
  default     = "AmazonEKSClusterAdminPolicy"
}

variable "cloudwatch_audit_enable" {
  description = "Enable CloudWatch audit logging for the bastion host"
  type        = bool
  default     = true
}

variable "cloudwatch_audit_retention_days" {
  description = "The number of days to retain CloudWatch audit logs"
  type        = number
  default     = 90
}

variable "additional_tags" {
  description = "Additional tags to apply to the resources"
  type        = map(string)
  default     = {}
}
