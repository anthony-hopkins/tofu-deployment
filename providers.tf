provider "vultr" {
  # api_key is deliberately not set here. The provider reads VULTR_API_KEY from
  # the environment, which keeps the key out of tfvars, out of the state file,
  # and out of anything `tofu show` will print.
  rate_limit  = var.vultr_rate_limit
  retry_limit = var.vultr_retry_limit
}
