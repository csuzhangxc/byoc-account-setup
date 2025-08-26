output "bastion_attributes" {
  description = "The name of the bastion instance"
  value = tomap({
    "bastion_name" = {
      for key, instance in module.bastions :
      key => instance.bastion_name
    }

    "instance_id" = {
      for key, instance in module.bastions :
      key => instance.bastion_instance.id
    }
  })
}

output "eks_cluster_access_policy" {
  description = "The access policy for the EKS cluster access"
  value       = var.eks_cluster_access_policy
}
