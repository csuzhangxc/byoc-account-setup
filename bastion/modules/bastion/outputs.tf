output "bastion_name" {
  description = "The name of the bastion instance"
  value       = var.bastion_name
}

output "bastion_instance" {
  description = "The bastion instance"
  value       = aws_instance.bastion_instance
}
