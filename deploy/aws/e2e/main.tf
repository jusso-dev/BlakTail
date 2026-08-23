data "aws_caller_identity" "current" {}

locals {
  name_prefix = "blaktail-e2e-${var.run_id}"
  tags = {
    Project   = "blaktail"
    Purpose   = "end-to-end-test"
    ManagedBy = "terraform"
    Owner     = "blaktail-e2e"
    RunId     = var.run_id
    ExpiresAt = var.expires_at
  }
}

resource "terraform_data" "safety_guard" {
  input = {
    account = data.aws_caller_identity.current.account_id
    run_id  = var.run_id
  }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_aws_account
      error_message = "Refusing AWS mutation: active account does not match expected_aws_account."
    }
    precondition {
      condition     = timecmp(var.expires_at, timestamp()) > 0
      error_message = "expires_at must be in the future."
    }
    precondition {
      condition     = timecmp(var.expires_at, timeadd(timestamp(), "24h")) <= 0
      error_message = "expires_at must be no more than 24 hours after apply."
    }
  }
}

module "bootstrap" {
  source = "./modules/bootstrap"

  name_prefix = local.name_prefix
  run_id      = var.run_id
  account_id  = data.aws_caller_identity.current.account_id
  tags        = local.tags

  depends_on = [terraform_data.safety_guard]
}

module "runtime" {
  count  = var.bootstrap_only ? 0 : 1
  source = "./modules/runtime"

  region                = var.region
  name_prefix           = local.name_prefix
  run_id                = var.run_id
  expires_at            = var.expires_at
  tags                  = local.tags
  artifact_bucket       = module.bootstrap.artifact_bucket
  console_image         = var.console_image
  coord_image           = var.coord_image
  relay_image           = var.relay_image
  coord_proxy_image     = var.coord_proxy_image
  deploy_services       = var.deploy_services
  console_desired_count = var.console_desired_count
}
