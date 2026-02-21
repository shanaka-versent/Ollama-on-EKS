# IAM Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "cluster_role_arn" {
  description = "EKS cluster IAM role ARN"
  value       = aws_iam_role.cluster.arn
}

output "cluster_role_name" {
  description = "EKS cluster IAM role name"
  value       = aws_iam_role.cluster.name
}

output "node_role_arn" {
  description = "EKS node group IAM role ARN"
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "EKS node group IAM role name"
  value       = aws_iam_role.node.name
}

output "ebs_csi_role_arn" {
  description = "EBS CSI Driver IAM role ARN"
  value       = var.create_ebs_csi_role ? aws_iam_role.ebs_csi[0].arn : null
}
