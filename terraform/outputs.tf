output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.region
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "sns_alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "gha_deployer_role_arn" {
  value       = try(aws_iam_role.github_actions[0].arn, null)
  description = "Set GitHub secret AWS_ROLE_ARN to this value"
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
