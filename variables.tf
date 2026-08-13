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

variable "defaults" {
  description = <<-EOT
    The baseline every instance inherits unless it overrides the field.

    Because these are defaults rather than per-instance settings, changing one
    here re-plans every instance that has not overridden it. plan and region
    changes are in-place resizes/moves where Vultr allows them; changing
    os_name rebuilds.
  EOT

  type = object({
    # 32 vCPU / 128 GB RAM / 1920 GB storage, AMD. See instances.auto.tfvars
    # for why this is the -1920s variant and not the bare vx1-g-32c-128g.
    plan        = optional(string, "vx1-g-32c-128g-1920s")
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
    condition     = var.defaults.plan != "" && var.defaults.region != ""
    error_message = "defaults.plan and defaults.region cannot be empty."
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

# --- Wordlist corpus (WORDLIST_* repository variables) ------------------------
# In CI these arrive as TF_VAR_wordlist_* from the GitHub repository variables
# and secrets of the same (upper-case) names. They are all-or-nothing: set all
# six to have cloud-init pull the dictionaries onto hashcat instances, leave all
# six unset to skip it and upload them yourself. A partial set fails the plan
# (precondition in main.tf).

variable "wordlist_directory" {
  description = "Absolute path the dictionaries are downloaded to. Normally <data_mount>/wordlists, so they land on the bulk disk rather than the root filesystem (GitHub variable WORDLIST_DIRECTORY)."
  type        = string
  default     = ""

  validation {
    condition     = var.wordlist_directory == "" || startswith(var.wordlist_directory, "/")
    error_message = "wordlist_directory must be an absolute path, e.g. /data/wordlists."
  }
}

variable "wordlist_endpoint" {
  description = "Vultr Object Storage endpoint hosting the dictionaries, with or without the https:// scheme, e.g. \"https://ewr1.vultrobjects.com\" (GitHub variable WORDLIST_ENDPOINT)."
  type        = string
  default     = ""
}

variable "wordlist_bucket" {
  description = "Object storage bucket holding the dictionaries (GitHub variable WORDLIST_BUCKET)."
  type        = string
  default     = ""
}

variable "wordlist_names" {
  description = <<-EOT
    Object keys to download, separated by commas or whitespace (GitHub variable
    WORDLIST_NAMES). A plain string rather than a list so it can be pasted
    straight into a GitHub repository variable:

      rockyou.txt.gz, corpora/weakpass_4.txt.gz, rules/best64.rule

    Each key keeps its basename on disk, so a prefixed key lands flat in
    wordlist_directory. Files are stored exactly as downloaded and are not
    unpacked -- hashcat 6 reads gzip-compressed wordlists natively, and a
    100 GB dictionary is better left compressed.
  EOT
  type        = string
  default     = ""
}

variable "wordlist_access_key" {
  description = "Object storage access key for the wordlist bucket (GitHub secret WORDLIST_ACCESS_KEY). Embedded in cloud-init user data -- treat instance user data as sensitive."
  type        = string
  default     = ""
  sensitive   = true
}

variable "wordlist_secret_key" {
  description = "Object storage secret key for the wordlist bucket (GitHub secret WORDLIST_SECRET_KEY). Embedded in cloud-init user data -- treat instance user data as sensitive."
  type        = string
  default     = ""
  sensitive   = true
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
    # hashcat = false leaves a plain hardened Ubuntu box: no cracking toolchain,
    # no data mount, no wordlist download.
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
