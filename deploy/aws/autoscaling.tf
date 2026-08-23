resource "aws_appautoscaling_target" "console" {
  max_capacity       = var.console_max_tasks
  min_capacity       = var.console_min_tasks
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.console.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "console_cpu" {
  name               = "${var.name}-console-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.console.resource_id
  scalable_dimension = aws_appautoscaling_target.console.scalable_dimension
  service_namespace  = aws_appautoscaling_target.console.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_target" "relay" {
  max_capacity       = var.relay_max_tasks
  min_capacity       = var.relay_min_tasks
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.relay.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "relay_cpu" {
  name               = "${var.name}-relay-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.relay.resource_id
  scalable_dimension = aws_appautoscaling_target.relay.scalable_dimension
  service_namespace  = aws_appautoscaling_target.relay.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 50
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
