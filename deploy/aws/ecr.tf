resource "aws_ecr_repository" "coord" {
  name                 = "${var.name}/coord"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = local.tags
}

resource "aws_ecr_repository" "relay" {
  name                 = "${var.name}/relay"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = local.tags
}

resource "aws_ecr_repository" "console" {
  name                 = "${var.name}/console"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = local.tags
}
