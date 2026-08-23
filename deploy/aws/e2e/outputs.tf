output "name_prefix" {
  description = "Run-scoped resource prefix and ECS service-name prefix."
  value       = local.name_prefix
}

output "region" {
  description = "AWS region containing this run."
  value       = var.region
}

output "run_id" {
  description = "Unique disposable run identifier."
  value       = var.run_id
}

output "public_url" {
  description = "Trusted API Gateway HTTPS URL for console and coordinator routes."
  value       = try(module.runtime[0].public_url, null)
}

output "relay_endpoint" {
  description = "Public UDP relay endpoint."
  value       = try(module.runtime[0].relay_endpoint, null)
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = try(module.runtime[0].cluster_name, null)
}

output "ecr_repository_urls" {
  description = "Immutable ECR repositories populated between bootstrap and runtime applies."
  value       = module.bootstrap.ecr_repository_urls
}

output "artifact_bucket" {
  description = "Private short-lived bucket for Linux agent packages and public-safe evidence."
  value       = module.bootstrap.artifact_bucket
}

output "task_definition_arns" {
  description = "Task definitions used for migration, services, and ECS Exec."
  value       = try(module.runtime[0].task_definition_arns, tomap({}))
}

output "private_subnet_ids" {
  description = "Private Fargate and agent subnet IDs."
  value = try(module.runtime[0].private_subnet_ids, {
    fargate = []
    agents  = []
  })
}

output "tasks_security_group_id" {
  description = "Security group required for one-off Fargate migration tasks."
  value       = try(module.runtime[0].tasks_security_group_id, null)
}

output "agent_instance_ids" {
  description = "Private SSM-managed Ubuntu and Amazon Linux agent instances."
  value       = try(module.runtime[0].agent_instance_ids, tomap({}))
}
