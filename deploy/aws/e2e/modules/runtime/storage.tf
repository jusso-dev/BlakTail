resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "better_auth" {
  length  = 48
  special = false
}

resource "random_password" "auth_hmac" {
  length  = 48
  special = false
}

resource "random_password" "relay_auth" {
  length  = 48
  special = false
}

resource "random_password" "diagnostics" {
  length  = 48
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = var.name_prefix
  subnet_ids = aws_subnet.tasks[*].id
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name_prefix}-db-"
  description = "Postgres from Fargate tasks only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Postgres from tasks"
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [aws_security_group.tasks.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_instance" "postgres" {
  identifier = var.name_prefix

  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = "blaktail"
  username               = "blaktail"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  multi_az                   = false
  publicly_accessible        = false
  backup_retention_period    = 0
  deletion_protection        = false
  skip_final_snapshot        = true
  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = merge(var.tags, { Component = "postgres" })
}

resource "aws_efs_file_system" "coord" {
  creation_token   = "${var.name_prefix}-coord"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = merge(var.tags, { Component = "coord-data" })
}

resource "aws_efs_access_point" "coord" {
  file_system_id = aws_efs_file_system.coord.id

  root_directory {
    path = "/data"
    creation_info {
      owner_gid   = 10001
      owner_uid   = 10001
      permissions = "0700"
    }
  }

  posix_user {
    gid = 10001
    uid = 10001
  }

  tags = var.tags
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.name_prefix}-efs-"
  description = "Coordinator EFS from Fargate tasks only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "NFS from tasks"
    protocol        = "tcp"
    from_port       = 2049
    to_port         = 2049
    security_groups = [aws_security_group.tasks.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_efs_mount_target" "coord" {
  count = 2

  file_system_id  = aws_efs_file_system.coord.id
  subnet_id       = aws_subnet.tasks[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_secretsmanager_secret" "console" {
  name                    = "${var.name_prefix}/console"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "console" {
  secret_id = aws_secretsmanager_secret.console.id
  secret_string = jsonencode({
    DATABASE_URL              = "postgresql://blaktail:${random_password.db.result}@${aws_db_instance.postgres.endpoint}/blaktail?sslmode=require"
    BETTER_AUTH_SECRET        = random_password.better_auth.result
    BLAKTAIL_AUTH_HMAC_SECRET = random_password.auth_hmac.result
  })
}

resource "aws_secretsmanager_secret" "control_plane" {
  name                    = "${var.name_prefix}/control-plane"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "control_plane" {
  secret_id = aws_secretsmanager_secret.control_plane.id
  secret_string = jsonencode({
    BLAKTAIL_AUTH_HMAC_SECRET  = random_password.auth_hmac.result
    BLAKTAIL_RELAY_AUTH_SECRET = random_password.relay_auth.result
    BLAKTAIL_DIAGNOSTICS_TOKEN = random_password.diagnostics.result
  })
}
