resource "aws_security_group" "agents" {
  name_prefix = "${var.name_prefix}-agents-"
  description = "No ingress; agents initiate SSM and BlakTail connections"
  vpc_id      = aws_vpc.this.id

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_instance" "ubuntu_agent" {
  ami                         = data.aws_ami.ubuntu_arm64.id
  instance_type               = "t4g.micro"
  subnet_id                   = aws_subnet.agents[0].id
  vpc_security_group_ids      = [aws_security_group.agents.id]
  iam_instance_profile        = aws_iam_instance_profile.agent.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_size = 12
    volume_type = "gp3"
  }

  user_data = <<-USER_DATA
    #!/bin/bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y awscli ca-certificates curl jq openssh-server wireguard-tools
    systemctl enable --now ssh
    snap list amazon-ssm-agent >/dev/null 2>&1 || snap install amazon-ssm-agent --classic
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
  USER_DATA

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-ubuntu"
    Platform = "ubuntu-24.04-arm64"
  })

  depends_on = [aws_route_table_association.agents]
}

resource "aws_instance" "al2023_agent" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = "t4g.micro"
  subnet_id                   = aws_subnet.agents[1].id
  vpc_security_group_ids      = [aws_security_group.agents.id]
  iam_instance_profile        = aws_iam_instance_profile.agent.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_size = 12
    volume_type = "gp3"
  }

  user_data = <<-USER_DATA
    #!/bin/bash
    set -euxo pipefail
    dnf install -y amazon-ssm-agent awscli2 ca-certificates curl jq openssh-server wireguard-tools
    systemctl enable --now sshd
    systemctl enable --now amazon-ssm-agent
  USER_DATA

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-al2023"
    Platform = "amazon-linux-2023-arm64"
  })

  depends_on = [aws_route_table_association.agents]
}
