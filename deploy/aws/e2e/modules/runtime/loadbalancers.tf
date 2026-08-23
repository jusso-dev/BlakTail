resource "aws_lb" "internal" {
  name               = "${local.lb_name_prefix}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.tasks[*].id

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = merge(var.tags, { Component = "internal-router" })
}

resource "aws_lb_target_group" "console" {
  name                 = "${local.lb_name_prefix}-console"
  port                 = 3000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.this.id
  target_type          = "ip"
  deregistration_delay = 10

  health_check {
    path                = "/sign-in"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_target_group" "coord" {
  name                 = "${local.lb_name_prefix}-coord"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.this.id
  target_type          = "ip"
  deregistration_delay = 10

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener" "internal" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.console.arn
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "coord" {
  listener_arn = aws_lb_listener.internal.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.coord.arn
  }

  condition {
    path_pattern {
      values = ["/health", "/v1", "/v1/*"]
    }
  }

  tags = var.tags
}

resource "aws_lb" "relay" {
  name                             = "${local.lb_name_prefix}-relay"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = aws_subnet.public[*].id
  security_groups                  = [aws_security_group.relay_nlb.id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false

  tags = merge(var.tags, { Component = "relay" })
}

resource "aws_lb_target_group" "relay" {
  name                 = "${local.lb_name_prefix}-relay"
  port                 = 3478
  protocol             = "UDP"
  vpc_id               = aws_vpc.this.id
  target_type          = "ip"
  deregistration_delay = 10

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "9702"
    path                = "/metrics"
    matcher             = "200"
    interval            = 10
    timeout             = 6
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = var.tags
}

resource "aws_lb_listener" "relay" {
  load_balancer_arn = aws_lb.relay.arn
  port              = 3478
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.relay.arn
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.name_prefix}"
  retention_in_days = 1
  tags              = var.tags
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = var.name_prefix
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = aws_subnet.tasks[*].id
  tags               = var.tags
}

resource "aws_apigatewayv2_api" "this" {
  name          = var.name_prefix
  protocol_type = "HTTP"

  disable_execute_api_endpoint = false

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "internal" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_lb_listener.internal.arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"
  timeout_milliseconds   = 30000

  request_parameters = {
    "overwrite:path" = "$request.path"
  }
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.internal.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 100
    throttling_rate_limit    = 50
  }

  tags = var.tags

  depends_on = [aws_apigatewayv2_route.default]
}
