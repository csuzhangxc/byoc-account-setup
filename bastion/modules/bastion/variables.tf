variable "bastion_name" {
  description = "Name to indentify this bastion and other aws resources"
  type        = string
  validation {
    # limited by tailscale hostname.
    condition     = length(var.bastion_name) <= 63
    error_message = "The length of name '${var.bastion_name}' is too long, max length is 63 bytes"
  }
}

variable "aws_region" {
  description = "AWS region to deploy the bastion host"
  type        = string
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
}

variable "eks_cluster_access_policy" {
  description = "The access policy for the EKS cluster access, see https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html"
  type        = string
  default     = "AmazonEKSClusterAdminPolicy"
}

variable "subnet_id" {
  description = "The ID of the subnet where the bastion host will be deployed, default to a random subnet in the EKS"
  type        = string
  default     = ""
}

variable "instance_ami_id" {
  description = "The AMI ID to use for the bastion host"
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "The instance type for the bastion host"
  type        = string
  default     = "t3.micro"
}

variable "auth_key" {
  description = "The auth key to login used by the bastion host"
  type        = string
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

