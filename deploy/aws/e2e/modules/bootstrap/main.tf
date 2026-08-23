terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "name_prefix" {
  type = string
}

variable "run_id" {
  type = string
}

variable "account_id" {
  type = string
}

variable "tags" {
  type = map(string)
}

locals {
  repositories = toset(["console", "coord", "relay", "coord-proxy"])
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name                 = "blaktail-e2e/${var.run_id}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, { Component = each.value })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Delete images after two days"
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 2
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name_prefix}-${var.account_id}-artifacts"
  force_destroy = true
  tags          = merge(var.tags, { Component = "artifacts" })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-e2e-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 2
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

output "ecr_repository_urls" {
  value = { for name, repository in aws_ecr_repository.this : replace(name, "-", "_") => repository.repository_url }
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.id
}
