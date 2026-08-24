terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

# Default VPC keeps the first deploy simple; move to a dedicated VPC for prod.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  tags = { Project = "blaktail", ManagedBy = "terraform" }
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "better_auth_secret" {
  length  = 48
  special = true
}

# Shared HMAC between console and coord for session assertions.
resource "random_password" "auth_hmac_secret" {
  length  = 48
  special = true
}

# Separate trust domain: compromise of a relay must not permit console-session
# forgery against the coordinator.
resource "random_password" "relay_auth_secret" {
  length  = 48
  special = true
}

resource "aws_secretsmanager_secret" "console_env" {
  name                    = "${var.name}/console-env"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "console_env" {
  secret_id = aws_secretsmanager_secret.console_env.id
  secret_string = jsonencode({
    BETTER_AUTH_SECRET        = random_password.better_auth_secret.result
    BLAKTAIL_AUTH_HMAC_SECRET = random_password.auth_hmac_secret.result
    DATABASE_URL              = "postgres://blaktail:${random_password.db.result}@${aws_db_instance.postgres.endpoint}/blaktail?sslmode=require"
  })
}

resource "aws_secretsmanager_secret" "coord_env" {
  name                    = "${var.name}/coord-env"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "coord_env" {
  secret_id = aws_secretsmanager_secret.coord_env.id
  secret_string = jsonencode({
    BLAKTAIL_AUTH_HMAC_SECRET  = random_password.auth_hmac_secret.result
    BLAKTAIL_RELAY_AUTH_SECRET = random_password.relay_auth_secret.result
    BLAKTAIL_DATABASE_URL      = "postgres://blaktail:${random_password.db.result}@${aws_db_instance.postgres.endpoint}/blaktail?sslmode=require"
    BLAKTAIL_TLS_CERT_PEM      = var.coord_tls_cert_pem
    BLAKTAIL_TLS_KEY_PEM       = var.coord_tls_key_pem
  })
}

resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.name}/db-master"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = "blaktail"
    password = random_password.db.result
  })
}
