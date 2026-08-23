variable "expected_aws_account" {
  description = "Twelve-digit AWS account allowed for this disposable run."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_aws_account))
    error_message = "expected_aws_account must be a twelve-digit AWS account ID."
  }
}

variable "region" {
  description = "Australian AWS region used by the relay and all test resources."
  type        = string
  default     = "ap-southeast-2"

  validation {
    condition     = var.region == "ap-southeast-2"
    error_message = "The end-to-end environment is pinned to ap-southeast-2."
  }
}

variable "run_id" {
  description = "Unique lowercase identifier for one disposable run."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{6,20}$", var.run_id))
    error_message = "run_id must contain six to twenty lowercase letters or digits."
  }
}

variable "expires_at" {
  description = "RFC3339 UTC expiry, no more than 24 hours after apply."
  type        = string

  validation {
    condition     = can(timecmp(var.expires_at, var.expires_at))
    error_message = "expires_at must be a valid RFC3339 timestamp."
  }
}

variable "bootstrap_only" {
  description = "Create only immutable ECR repositories and artifact bucket."
  type        = bool
  default     = false
}

variable "deploy_services" {
  description = "Run ECS services. Keep false while running the one-off DB migration."
  type        = bool
  default     = false
}

variable "console_desired_count" {
  description = "Console tasks to run after the one-off migration succeeds."
  type        = number
  default     = 1

  validation {
    condition     = var.console_desired_count >= 0 && var.console_desired_count <= 2 && floor(var.console_desired_count) == var.console_desired_count
    error_message = "console_desired_count must be an integer from zero to two."
  }
}

variable "console_image" {
  description = "ARM64 console image pinned by sha256 digest."
  type        = string
  default     = ""

  validation {
    condition     = var.bootstrap_only || can(regex("@sha256:[0-9a-f]{64}$", var.console_image))
    error_message = "console_image must end in @sha256:<64 lowercase hex characters>."
  }
}

variable "coord_image" {
  description = "ARM64 coordinator image pinned by sha256 digest."
  type        = string
  default     = ""

  validation {
    condition     = var.bootstrap_only || can(regex("@sha256:[0-9a-f]{64}$", var.coord_image))
    error_message = "coord_image must end in @sha256:<64 lowercase hex characters>."
  }
}

variable "relay_image" {
  description = "ARM64 relay image pinned by sha256 digest."
  type        = string
  default     = ""

  validation {
    condition     = var.bootstrap_only || can(regex("@sha256:[0-9a-f]{64}$", var.relay_image))
    error_message = "relay_image must end in @sha256:<64 lowercase hex characters>."
  }
}

variable "coord_proxy_image" {
  description = "ARM64 Caddy coordinator bridge image pinned by sha256 digest."
  type        = string
  default     = ""

  validation {
    condition     = var.bootstrap_only || can(regex("@sha256:[0-9a-f]{64}$", var.coord_proxy_image))
    error_message = "coord_proxy_image must end in @sha256:<64 lowercase hex characters>."
  }
}
