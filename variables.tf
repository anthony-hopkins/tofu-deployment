variable "project" {
  description = "Short name used as the ownership tag on every instance."
  type        = string
  default     = "crackbox"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be 2-21 characters of lowercase letters, digits and hyphens, starting with a letter or digit."
  }
}

variable "dns_zone" {
  description = <<-EOT
    DNS zone the boxes sit under. When set, an instance's hostname and label
    default to "<key>.<dns_zone>" -- e.g. "crack01.dhs-labs.us". Set to "" to
    fall back to "<project>-<key>".

    This only shapes names. Nothing here creates DNS records.
  EOT
  type        = string
  default     = "dhs-labs.us"
}

variable "vultr_plan" {
  description = <<-EOT
    Vultr plan ID every instance inherits unless it sets its own `plan`.

    Required, with no default on purpose: the box size is a deployment setting,
    not a committed constant, and an unset value should fail rather than quietly
    size the box for you. CI passes the VULTR_PLAN repository variable in as
    TF_VAR_vultr_plan; a local run must export TF_VAR_vultr_plan (or answer the
    prompt) -- e.g. `export TF_VAR_vultr_plan=vx1-g-32c-128g-1920s`.

    The usual value is 32 vCPU / 128 GB RAM / 1920 GB storage, AMD, no GPU. The
    -1920s suffix is what buys the disk -- the bare vx1-g-32c-128g ships a 1 GB
    boot disk and expects block storage attached separately, with nowhere to
    put a dictionary corpus. See "About that plan" in the README before
    choosing one, and run `make plans REGION=sea` for the catalogue.
  EOT
  type        = string

  validation {
    condition     = var.vultr_plan != ""
    error_message = "vultr_plan cannot be empty. Set the VULTR_PLAN repository variable (or export TF_VAR_vultr_plan). Run `make plans REGION=sea` for the catalogue."
  }
}

variable "defaults" {
  description = <<-EOT
    The baseline every instance inherits unless it overrides the field.

    Because these are defaults rather than per-instance settings, changing one
    here re-plans every instance that has not overridden it. A region change is
    an in-place move where Vultr allows it; changing os_name rebuilds. The plan
    is not a default -- it comes from var.vultr_plan (the VULTR_PLAN repository
    variable in CI).
  EOT

  type = object({
    region      = optional(string, "sea")                  # Seattle
    os_name     = optional(string, "Ubuntu 26.04 LTS x64") # os_id 2760
    user_scheme = optional(string, "root")
    hashcat     = optional(bool, true)
    enable_ipv6 = optional(bool, true)
    backups     = optional(bool, false)
  })

  default = {}

  validation {
    condition     = contains(["root", "limited"], var.defaults.user_scheme)
    error_message = "defaults.user_scheme must be either \"root\" or \"limited\"."
  }

  validation {
    condition     = var.defaults.region != ""
    error_message = "defaults.region cannot be empty."
  }

  validation {
    condition     = var.defaults.os_name != ""
    error_message = "defaults.os_name cannot be empty. Run `make os` for the exact image names."
  }
}

variable "admin_user" {
  description = <<-EOT
    Admin account cloud-init creates on every instance. It receives the
    instance's SSH public keys, passwordless sudo, ownership of the data
    mount, and a random password generated on the machine itself -- printed
    only to the serial console, never stored in state. Root SSH login is
    disabled in its favor.
  EOT
  type        = string
  default     = "ahopkins"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_user))
    error_message = "admin_user must be a valid Linux username: lowercase letters, digits, hyphens and underscores, at most 32 characters, not starting with a digit."
  }
}

variable "data_mount" {
  description = <<-EOT
    Where the bulk storage is mounted on hashcat instances, and the parent of
    the wordlists/, hashes/, rules/ and sessions/ working directories.

    The vx1 plans carry their storage as a separate device rather than as room
    on the root disk, so cloud-init looks for the largest unformatted, unmounted
    disk and mounts it here by UUID. When there is no such device -- a plan with
    everything on the root disk, or a re-run -- the directories are simply
    created in place and the mount is skipped.
  EOT
  type        = string
  default     = "/data"

  validation {
    condition     = startswith(var.data_mount, "/") && var.data_mount != "/"
    error_message = "data_mount must be an absolute path below the root, e.g. /data."
  }
}

# --- Public corpora pulled on first boot -------------------------------------
# Both are plain anonymous downloads: no credentials, nothing sensitive baked
# into user data, and both are skipped by setting them to "".

variable "rockyou_url" {
  description = <<-EOT
    Gzipped rockyou wordlist, downloaded and extracted into the admin user's
    home directory as ~/rockyou.txt on hashcat instances.

    Roughly 53 MB on the wire, 134 MB extracted -- small enough for the home
    directory, unlike the corpora that belong on the data mount. The URL 302s
    to download.weakpass.com, which is why the fetch follows redirects. Set to
    "" to skip it.
  EOT
  type        = string
  default     = "https://weakpass.com/download/90/rockyou.txt.gz"

  validation {
    condition     = var.rockyou_url == "" || can(regex("^https?://", var.rockyou_url))
    error_message = "rockyou_url must be an http(s) URL, or \"\" to skip the download."
  }
}

variable "seclists_repo" {
  description = <<-EOT
    SecLists source repository, shallow-cloned to <data_mount>/seclists with
    /usr/share/seclists symlinked at it.

    SecLists is NOT an Ubuntu package. `apt install seclists` works on Kali,
    which is where that instruction usually comes from, but the name is in no
    Ubuntu suite at all and the install would fail -- so it comes from
    upstream instead. It is over a gigabyte checked out, which is why it lands
    on the bulk disk rather than the root filesystem, and why the clone is
    --depth 1. Set to "" to skip it.
  EOT
  type        = string
  default     = "https://github.com/danielmiessler/SecLists.git"

  validation {
    condition     = var.seclists_repo == "" || can(regex("^(https?://|git@)", var.seclists_repo))
    error_message = "seclists_repo must be an http(s) or git@ URL, or \"\" to skip the clone."
  }
}

variable "vultr_rate_limit" {
  description = "Milliseconds the provider waits between Vultr API calls. Vultr allows ~30 calls/second."
  type        = number
  default     = 500
}

variable "vultr_retry_limit" {
  description = "How many times the provider retries a failed Vultr API call."
  type        = number
  default     = 3
}

variable "ssh_key_names" {
  description = <<-EOT
    Names of SSH keys that already exist in your Vultr account, applied to every
    instance that does not set its own ssh_key_names. Looked up by name via the
    vultr_ssh_key data source, so a name that is not in the account fails at
    plan time rather than producing an instance you cannot log into.
  EOT
  type        = list(string)
  default     = []
}

variable "instances" {
  description = <<-EOT
    The fleet, keyed by short instance name.

    Every field except the map key is optional: `crack01 = {}` gets you the full
    var.defaults baseline. Set a field to override just that one.

    The map key is the for_each key, the DNS label, and the value stamped into
    the `instance:<key>` tag, which is how the snapshot and diagnose scripts
    find a machine. Renaming a key destroys and recreates the instance -- to
    rename without rebuilding, set `label` and `hostname` instead.
  EOT

  type = map(object({
    # --- Placement. null inherits from var.defaults ------------------------
    plan   = optional(string)
    region = optional(string)

    # --- Image source -------------------------------------------------------
    # snapshot_id takes precedence over os_name when both are set.
    os_name     = optional(string)
    snapshot_id = optional(string)

    # --- Identity -----------------------------------------------------------
    hostname = optional(string) # defaults to "<key>.<dns_zone>"
    label    = optional(string) # defaults to the same
    tags     = optional(list(string), [])

    # --- Access and networking ----------------------------------------------
    ssh_key_names       = optional(list(string)) # null inherits var.ssh_key_names
    firewall_group_id   = optional(string)
    vpc_ids             = optional(list(string), [])
    vpc_only            = optional(bool, false)
    enable_ipv6         = optional(bool)
    disable_public_ipv4 = optional(bool, false)
    ddos_protection     = optional(bool, false)
    user_scheme         = optional(string)

    # --- Vultr automatic backups (billed separately from snapshots) ---------
    backups = optional(bool)
    backup_schedule = optional(object({
      type = optional(string, "daily") # daily|weekly|monthly|daily_alt_even|daily_alt_odd
      hour = optional(number, 3)       # UTC hour, 0-23
      dow  = optional(number)          # 1=Sunday .. 7=Saturday, for type=weekly
      dom  = optional(number)          # 1-28, for type=monthly
    }))

    # --- Payload (rendered into cloud-init) ---------------------------------
    # hashcat = false leaves a plain hardened Ubuntu box: no cracking toolchain
    # and no data mount.
    hashcat          = optional(bool)
    extra_packages   = optional(list(string), [])
    extra_cloud_init = optional(string) # raw YAML merged in as top-level keys
  }))

  default = {}

  # Cross-field rules that need a resolved value (backups vs schedule, IPv4 vs
  # IPv6, SSH keys) live as preconditions in main.tf, where the inherited
  # defaults have already been applied.

  validation {
    condition = alltrue([
      for k in keys(var.instances) : can(regex("^[a-z0-9][a-z0-9-]{0,30}$", k))
    ])
    error_message = "Instance keys must be 1-31 characters of lowercase letters, digits and hyphens. They become DNS labels and -target addresses."
  }

  validation {
    condition = alltrue([
      for k, v in var.instances :
      v.user_scheme == null ? true : contains(["root", "limited"], v.user_scheme)
    ])
    error_message = "user_scheme must be either \"root\" or \"limited\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.instances :
      v.backup_schedule == null ? true : contains(
        ["daily", "weekly", "monthly", "daily_alt_even", "daily_alt_odd"],
        v.backup_schedule.type
      )
    ])
    error_message = "backup_schedule.type must be one of: daily, weekly, monthly, daily_alt_even, daily_alt_odd."
  }

  validation {
    condition = alltrue([
      for k, v in var.instances :
      v.snapshot_id == null ? true : can(regex("^[0-9a-f-]{36}$", v.snapshot_id))
    ])
    error_message = "snapshot_id must be a Vultr snapshot UUID. Run the snapshot workflow with action=list to see the available IDs."
  }
}
