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
    package_ready=false
    for attempt in {1..30}; do
      if apt-get update -o Acquire::ForceIPv4=true && \
        apt-get install -y ca-certificates curl jq openssh-server wireguard-tools; then
        package_ready=true
        break
      fi
      sleep 10
    done
    [ "$package_ready" = true ]
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
    package_ready=false
    for attempt in {1..30}; do
      if dnf install -y amazon-ssm-agent ca-certificates jq openssh-server wireguard-tools; then
        package_ready=true
        break
      fi
      sleep 10
    done
    [ "$package_ready" = true ]
    systemctl enable --now sshd
    systemctl enable --now amazon-ssm-agent
    systemctl enable --now systemd-resolved
    if grep -Eq '^[[:space:]]*hosts:[[:space:]]+files[[:space:]]+dns[[:space:]]+myhostname[[:space:]]*$' /etc/nsswitch.conf; then
      sed -i -E 's/^[[:space:]]*hosts:[[:space:]]+files[[:space:]]+dns[[:space:]]+myhostname[[:space:]]*$/hosts:      files resolve [!UNAVAIL=return] dns myhostname/' /etc/nsswitch.conf
    elif ! grep -Eq '^[[:space:]]*hosts:.*[[:space:]]resolve([[:space:]]|$)' /etc/nsswitch.conf; then
      echo 'unsupported AL2023 hosts configuration' >&2
      exit 1
    fi
    ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
  USER_DATA

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-al2023"
    Platform = "amazon-linux-2023-arm64"
  })

  depends_on = [aws_route_table_association.agents]
}
