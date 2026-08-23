resource "aws_vpc" "this" {
  cidr_block           = "10.88.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  })
}

resource "aws_subnet" "tasks" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.task_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-tasks-${count.index + 1}"
    Tier = "private-fargate"
  })
}

resource "aws_subnet" "agents" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.agent_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-agent-${count.index + 1}"
    Tier = "private-agent"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "nat" {
  name_prefix = "${var.name_prefix}-nat-"
  description = "Forward private task and agent egress only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Private subnet forwarding"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = concat(local.task_cidrs, local.agent_cidrs)
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_instance" "nat" {
  count = 2

  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public[count.index].id
  vpc_security_group_ids      = [aws_security_group.nat.id]
  associate_public_ip_address = true
  source_dest_check           = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = <<-USER_DATA
    #!/bin/bash
    set -euxo pipefail
    dnf install -y iptables-services
    cat >/etc/sysctl.d/99-blaktail-nat.conf <<'SYSCTL'
    net.ipv4.ip_forward = 1
    SYSCTL
    sysctl --system
    iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
    iptables -A FORWARD -i ens5 -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -o ens5 -j ACCEPT
    service iptables save
    systemctl enable iptables
  USER_DATA

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-nat-${count.index + 1}"
    Component = "nat-instance"
  })

  depends_on = [aws_route_table_association.public]
}

resource "aws_route_table" "tasks" {
  count = 2

  vpc_id = aws_vpc.this.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat[count.index].primary_network_interface_id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tasks-${count.index + 1}" })
}

resource "aws_route_table_association" "tasks" {
  count = 2

  subnet_id      = aws_subnet.tasks[count.index].id
  route_table_id = aws_route_table.tasks[count.index].id
}

resource "aws_route_table" "agents" {
  count = 2

  vpc_id = aws_vpc.this.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat[count.index].primary_network_interface_id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-agent-${count.index + 1}" })
}

resource "aws_route_table_association" "agents" {
  count = 2

  subnet_id      = aws_subnet.agents[count.index].id
  route_table_id = aws_route_table.agents[count.index].id
}
