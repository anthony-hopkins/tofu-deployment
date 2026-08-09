terraform {
  # State lives in VULTR OBJECT STORAGE, not AWS.
  #
  # `backend "s3"` names a protocol, not a vendor: it is OpenTofu's client for
  # any S3-compatible object store, and here it is pointed at
  # <cluster>.vultrobjects.com. There is no AWS account and no AWS service in
  # this path. OpenTofu ships no Vultr-specific backend, so this is the
  # supported way to keep state on Vultr.
  #
  # The credentials are read from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  # because those are the environment variables the underlying AWS SDK looks
  # at. The values are your Vultr Object Storage S3 keys. The names cannot be
  # changed; OpenTofu recommends against putting the keys in this file.
  #
  # Partial configuration: the bucket, region and endpoint are
  # environment-specific and supplied at init time from a generated
  # backend.hcl. Run scripts/bootstrap-backend.sh to produce it.
  #
  #   tofu init -backend-config=backend.hcl
  #
  # See backend.hcl.example, `make backend.hcl`, and the tofu-init composite
  # action which writes the same file from repository variables in CI.
  backend "s3" {
    key = "containerlabs/terraform.tfstate"

    # Vultr Object Storage speaks S3 but is not AWS. Each of these disables an
    # AWS-only preflight call that would otherwise fail against the Vultr
    # endpoint before any state operation is attempted.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true

    # Vultr rejects the trailing-checksum upload format the AWS SDK now
    # defaults to; without this, state writes fail with a signature error.
    skip_s3_checksum = true

    # Vultr uses path-style addressing (endpoint/bucket/key), not
    # virtual-hosted-style (bucket.endpoint/key).
    use_path_style = true

    # Best-effort mutual exclusion via a .tflock object in the state bucket.
    # This relies on S3 conditional writes, which not every S3-compatible
    # provider implements; the workflows additionally serialize themselves
    # with a GitHub Actions concurrency group, which does not depend on it.
    use_lockfile = true
  }
}
