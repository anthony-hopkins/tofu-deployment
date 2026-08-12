variable "project" {
  description = "Short name used as the ownership tag on every instance."
  type        = string
  default     = "containerlabs"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be 2-21 characters of lowercase letters, digits and hyphens, starting with a letter or digit."
  }
}

variable "dns_zone" {
  description = <<-EOT
    DNS zone the labs sit under. When set, an instance's hostname and label
    default to "<key>.<dns_zone>" -- matching the existing
    containerlabs.dhs-labs.us box. Set to "" to fall back to "<project>-<key>".

    This only shapes names. Nothing here creates DNS records.
  EOT
  type        = string
  default     = "dhs-labs.us"
}

variable "defaults" {
  description = <<-EOT
    The baseline every instance inherits unless it overrides the field.
    Modelled on the existing containerlabs.dhs-labs.us instance.

    Because these are defaults rather than per-instance settings, changing one
    here re-plans every instance that has not overridden it. plan and region
    changes are in-place resizes/moves where Vultr allows them; changing
    os_name rebuilds.
  EOT

  type = object({
    plan        = optional(string, "vhp-4c-12gb-amd")      # 4 vCPU, 12 GB, 260 GB AMD NVMe
    region      = optional(string, "lax")                  # Los Angeles
    os_name     = optional(string, "Ubuntu 26.04 LTS x64") # os_id 2760
    user_scheme = optional(string, "root")
    docker      = optional(bool, true)
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
    instance's SSH public keys, passwordless sudo, docker group membership
    (when docker is enabled), and a random password generated on the machine
    itself -- printed only to the serial console, never stored in state. Root
    SSH login is disabled in its favor.
  EOT
  type        = string
  default     = "ahopkins"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_user))
    error_message = "admin_user must be a valid Linux username: lowercase letters, digits, hyphens and underscores, at most 32 characters, not starting with a digit."
  }
}

variable "course_repo" {
  description = <<-EOT
    Git repository cloud-init clones into the admin user's home on
    docker-enabled instances (public URL, no auth). Its common/host-image/
    directory is built as the netcourse-host:latest Docker image on first
    boot; the clone stays in the home directory afterwards. Set to "" to
    skip the clone and build.
  EOT
  type        = string
  default     = "https://github.com/anthony-hopkins/network-course.git"
}

# --- cEOS lab image (IMG_* repository variables) -----------------------------
# In CI these arrive as TF_VAR_img_* from the GitHub repository variables and
# secrets of the same (upper-case) names. They are all-or-nothing: set all six
# to have cloud-init download the image on docker-enabled instances, leave all
# six unset to skip it. A partial set fails the plan (precondition in main.tf).

variable "img_directory" {
  description = "Absolute path created on docker-enabled instances where the cEOS tarball is staged (GitHub variable IMG_DIRECTORY). Owned by var.admin_user; the tarball itself is removed after the docker import, leaving only the image."
  type        = string
  default     = ""

  validation {
    condition     = var.img_directory == "" || startswith(var.img_directory, "/")
    error_message = "img_directory must be an absolute path, e.g. /opt/images."
  }
}

variable "img_endpoint" {
  description = "Vultr Object Storage endpoint hosting the cEOS image, with or without the https:// scheme, e.g. \"https://ewr1.vultrobjects.com\" (GitHub variable IMG_ENDPOINT)."
  type        = string
  default     = ""
}

variable "img_bucket" {
  description = "Object storage bucket holding the cEOS image (GitHub variable IMG_BUCKET)."
  type        = string
  default     = ""
}

variable "img_name" {
  description = "Object key of the cEOS image tarball, e.g. cEOS64-lab-4.32.2F.tar.xz (GitHub variable IMG_NAME). Also the filename it lands under in img_directory."
  type        = string
  default     = ""
}

variable "img_access_key" {
  description = "Object storage access key for the image bucket (GitHub secret IMG_ACCESS_KEY). Embedded in cloud-init user data -- treat instance user data as sensitive."
  type        = string
  default     = ""
  sensitive   = true
}

variable "img_secret_key" {
  description = "Object storage secret key for the image bucket (GitHub secret IMG_SECRET_KEY). Embedded in cloud-init user data -- treat instance user data as sensitive."
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
    The lab fleet, keyed by short instance name.

    Every field except the map key is optional: `lab01 = {}` gets you the full
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

    # --- Lab payload (rendered into cloud-init) -----------------------------
    docker           = optional(bool)
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
