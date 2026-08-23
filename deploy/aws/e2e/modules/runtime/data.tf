data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_cidrs = ["10.88.0.0/24", "10.88.1.0/24"]
  task_cidrs   = ["10.88.10.0/24", "10.88.11.0/24"]
  agent_cidrs  = ["10.88.20.0/24", "10.88.21.0/24"]

  # ALB/NLB names cap at 32 characters. Preserve uniqueness with a run hash;
  # full run identity remains in names that permit it and every resource tag.
  lb_name_prefix = "bte2e-${substr(var.run_id, 0, 9)}-${substr(sha1(var.run_id), 0, 6)}"

  public_url     = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
  relay_endpoint = "${aws_lb.relay.dns_name}:3478"

  log_options = {
    awslogs-region        = var.region
    awslogs-stream-prefix = "service"
  }
}
