resource "aws_efs_file_system" "coord" {
  creation_token   = "${var.name}-coord"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  tags             = local.tags
}

resource "aws_efs_mount_target" "coord" {
  count           = length(data.aws_subnets.default.ids)
  file_system_id  = aws_efs_file_system.coord.id
  subnet_id       = data.aws_subnets.default.ids[count.index]
  security_groups = [aws_security_group.tasks.id]
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

  tags = local.tags
}
