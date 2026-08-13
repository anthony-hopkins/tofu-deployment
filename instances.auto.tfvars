# The fleet. This file is the source of truth: change it in a PR, let the plan
# workflow show the diff, then run the apply workflow to make it real.

project  = "crackbox"
dns_zone = "dhs-labs.us"

# The baseline every instance inherits. Override any field per instance below.
#
# The plan is NOT set here. It is a required deployment setting rather than a
# committed constant -- it comes from var.vultr_plan, which has no default: CI
# feeds it from the VULTR_PLAN repository variable (TF_VAR_vultr_plan), and a
# local run must export TF_VAR_vultr_plan. See variables.tf and "About that
# plan" in the README. Run `make plans REGION=sea` for the catalogue.
#
# Region is "sea" because the default plan is not offered in lax. Available in:
# ewr, ord, sea, atl, ams, nrt. Run `make plans REGION=sea` to confirm, and
# `make os` for exact image names.
defaults = {
  region      = "sea"
  os_name     = "Ubuntu 26.04 LTS x64"
  user_scheme = "root"
  hashcat     = true
  enable_ipv6 = true
  backups     = false
}

# SSH keys must already exist in your Vultr account (Account -> SSH Keys).
# Looked up by name, so a typo fails at plan time instead of locking you out.
ssh_key_names = [
  "kubuntu26-de",
]

# The dictionary corpus is NOT configured here. WORDLIST_* is all-or-nothing
# and two of the six are object storage credentials, which do not belong in a
# committed file -- they arrive as TF_VAR_wordlist_* from the environment
# locally and from repository variables/secrets in CI. See the README.

instances = {
  crack01 = {}
}
