output "prometheus_service_name" {
  description = "Name of the Prometheus service"
  value       = "kube-prometheus-stack-prometheus"
}

output "sns_topic_arn" {
  description = "ARN of the alerts SNS topic"
  value       = var.alert_email != "" ? aws_sns_topic.alerts[0].arn : ""
}
