# AWS Load Balancer Controller Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "release_name" {
  description = "Helm release name"
  value       = helm_release.aws_load_balancer_controller.name
}
