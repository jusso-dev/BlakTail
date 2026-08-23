terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "region" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "run_id" {
  type = string
}

variable "expires_at" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "artifact_bucket" {
  type = string
}

variable "console_image" {
  type = string
}

variable "coord_image" {
  type = string
}

variable "relay_image" {
  type = string
}

variable "coord_proxy_image" {
  type = string
}

variable "deploy_services" {
  type = bool
}

variable "console_desired_count" {
  type = number
}
