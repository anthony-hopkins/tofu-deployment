terraform {
  # use_lockfile (S3-native state locking, no DynamoDB) landed in OpenTofu 1.10.
  # Vultr Object Storage has no DynamoDB equivalent, so this is the only
  # in-backend locking option available to us.
  required_version = ">= 1.10.0"

  required_providers {
    vultr = {
      source = "vultr/vultr"
      # >= 2.32, < 3.0. Not lower: main.tf sets `vpc_only`, which the provider
      # only gained in v2.32.0 (2026-07-14). A looser constraint resolves to a
      # version without that attribute, which is also what makes editor
      # language servers report "Unexpected attribute: vpc_only".
      version = "~> 2.32"
    }
  }
}
