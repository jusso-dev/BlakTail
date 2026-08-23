output "public_url" {
  value = local.public_url
}

output "relay_endpoint" {
  value = local.relay_endpoint
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "task_definition_arns" {
  value = {
    console = aws_ecs_task_definition.console.arn
    coord   = aws_ecs_task_definition.coord.arn
    relay   = aws_ecs_task_definition.relay.arn
  }
}

output "private_subnet_ids" {
  value = {
    fargate = aws_subnet.tasks[*].id
    agents  = aws_subnet.agents[*].id
  }
}

output "tasks_security_group_id" {
  value = aws_security_group.tasks.id
}

output "agent_instance_ids" {
  value = {
    ubuntu = aws_instance.ubuntu_agent.id
    al2023 = aws_instance.al2023_agent.id
  }
}
