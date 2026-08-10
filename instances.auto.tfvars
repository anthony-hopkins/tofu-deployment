# The lab fleet. This file is the source of truth: change it in a PR, let the
# plan workflow show the diff, then run the apply workflow to make it real.

project  = "containerlabs"
dns_zone = "dhs-labs.us"

# The baseline every instance inherits. Modelled on the existing
# containerlabs.dhs-labs.us box. Override any field per instance below.
#
#   vhp-4c-12gb-amd  4 vCPU / 12 GB / 260 GB AMD NVMe / 7 TB transfer / $72 mo
#
# Run `make plans` for alternatives available in the region, `make os` for
# exact image names.
defaults = {
  plan        = "vhp-4c-12gb-amd"
  region      = "lax"
  os_name     = "Ubuntu 26.04 LTS x64"
  user_scheme = "root"
  docker      = true
  enable_ipv6 = true
  backups     = false
}

# SSH keys must already exist in your Vultr account (Account -> SSH Keys).
# Looked up by name, so a typo fails at plan time instead of locking you out.
ssh_key_names = [
  "kubuntu26-de",
]

instances = {
  lab01 = {}
}
