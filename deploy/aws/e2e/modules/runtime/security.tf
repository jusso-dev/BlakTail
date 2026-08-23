resource "aws_security_group" "vpc_link" {
  name_prefix = "${var.name_prefix}-vpclink-"
  description = "API Gateway VPC link to internal ALB"
  vpc_id      = aws_vpc.this.id

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  description = "Internal ALB accepts only API Gateway VPC link traffic"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP from API Gateway VPC link"
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.vpc_link.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_security_group" "relay_nlb" {
  name_prefix = "${var.name_prefix}-nlb-"
  description = "Public UDP relay entry point"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "BlakTail relay UDP"
    protocol    = "udp"
    from_port   = 3478
    to_port     = 3478
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_security_group" "tasks" {
  name_prefix = "${var.name_prefix}-tasks-"
  description = "Private Fargate control-plane tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Console from internal ALB"
    protocol        = "tcp"
    from_port       = 3000
    to_port         = 3000
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Coordinator proxy from internal ALB"
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Relay UDP from public NLB"
    protocol        = "udp"
    from_port       = 3478
    to_port         = 3478
    security_groups = [aws_security_group.relay_nlb.id]
  }

  ingress {
    description     = "Relay HTTP health from public NLB"
    protocol        = "tcp"
    from_port       = 9702
    to_port         = 9702
    security_groups = [aws_security_group.relay_nlb.id]
  }

  ingress {
    description = "Private metrics between tasks"
    protocol    = "tcp"
    from_port   = 9701
    to_port     = 9702
    self        = true
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}
