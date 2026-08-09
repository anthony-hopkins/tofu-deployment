terraform {
  # use_lockfile (S3-native state locking, no DynamoDB) landed in OpenTofu 1.10.
  # Vultr Object Storage has no DynamoDB equivalent, so this is the only
  # in-backend locking option available to us.
  required_version = ">= 1.10.0"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.26"
    }
  }
}
