# The fleet. This file is the source of truth: change it in a PR, let the plan
# workflow show the diff, then run the apply workflow to make it real.

project  = "crackbox"
dns_zone = "dhs-labs.us"

# The baseline every instance inherits. Override any field per instance below.
#
#   vx1-g-32c-128g-1920s  32 vCPU / 128 GB / 1920 GB / AMD / $892.79 mo
#
# Two things about this plan are worth knowing before you change it:
#
#   * It has no GPU. The "g" is "general purpose" (as opposed to the "m",
#     memory-optimized, half of the vx1 family) -- the plans API reports
#     gpu_brand "none". Cracking happens on 32 AMD threads through pocl, which
#     is an order of magnitude off a mid-range GPU on fast hashes and much
#     closer on the slow ones (bcrypt, scrypt, argon2). If that trade stops
#     making sense, the vcg-* plans carry NVIDIA cards and would need an
#     NVIDIA/CUDA install added to the cloud-init payload.
#
#   * The "-1920s" suffix is what buys the disk. The bare vx1-g-32c-128g is
#     $700.80/mo but ships a 1 GB boot disk and expects block storage to be
#     attached separately -- nowhere to put a dictionary corpus.
#
# Region is "sea" because this plan is not offered in lax. Available in:
# ewr, ord, sea, atl, ams, nrt. Run `make plans REGION=sea` to confirm, and
# `make os` for exact image names.
defaults = {
  plan        = "vx1-g-32c-128g-1920s"
  region      = "sea"
  os_name     = "Ubuntu 26.04 LTS x64"
  user_scheme = "root"
  hashcat     = true
  enable_ipv6 = true

  # Vultr automatic backups are a percentage surcharge on the instance price,
  # charged continuously for as long as the box exists. On a plan this size
  # that is the single easiest line item to waste money on, and it buys
  # scheduled images of a machine that is meant to live for the length of one
  # cracking run. Snapshots cover the same need on demand -- take one before a
  # risky change or a destroy, keep the ones worth keeping, prune the rest.
  # See "Snapshots and restore" in the README.
  backups = false
}

# SSH keys must already exist in your Vultr account (Account -> SSH Keys).
# Looked up by name, so a typo fails at plan time instead of locking you out.
ssh_key_names = [
  "kubuntu26-de",
]

# Two public corpora come down on first boot: rockyou extracted into the admin
# user's home, and SecLists shallow-cloned onto the data mount. Both are
# variables with defaults (see variables.tf) -- set rockyou_url or
# seclists_repo to "" to skip either. Anything private still gets uploaded by
# hand into /data/wordlists, which cloud-init creates empty. See "Getting
# dictionaries onto the box" in the README.

instances = {
  crack01 = {}
}
