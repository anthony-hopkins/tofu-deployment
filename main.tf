resource "vultr_instance" "this" {
  for_each = local.effective

  region = each.value.region
  plan   = each.value.plan

  # Exactly one of these is non-null; the other is omitted from the API call.
  os_id       = each.value.snapshot_id != null ? null : tonumber(data.vultr_os.this[each.value.os_name].id)
  snapshot_id = each.value.snapshot_id

  hostname = each.value.fqdn
  label    = each.value.label
  tags     = each.value.tags

  ssh_key_ids       = [for n in each.value.ssh_key_names : data.vultr_ssh_key.this[n].id]
  firewall_group_id = each.value.firewall_group_id
  vpc_ids           = each.value.vpc_ids
  vpc_only          = each.value.vpc_only

  enable_ipv6         = each.value.enable_ipv6
  disable_public_ipv4 = each.value.disable_public_ipv4
  ddos_protection     = each.value.ddos_protection
  user_scheme         = each.value.user_scheme

  # The provider base64-encodes this for us, so it is plain YAML here.
  # cloud-init only runs on first boot: editing the template and applying
  # updates the user data Vultr has on file but changes nothing on a running
  # instance until it is reinstalled or rebuilt.
  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    project      = var.project
    instance_key = each.key
    hostname     = each.value.short_hostname
    fqdn         = each.value.fqdn
    hashcat      = each.value.hashcat
    data_mount   = var.data_mount

    # Vultr only injects ssh_key_ids into root/linuxuser, so the admin user
    # gets the same public keys planted via cloud-init.
    admin_user      = var.admin_user
    ssh_public_keys = [for n in each.value.ssh_key_names : trimspace(data.vultr_ssh_key.this[n].ssh_key)]

    # null when the WORDLIST_* variables are unset; the template then renders
    # no download script and the box comes up with empty wordlists/.
    wordlists = local.wordlist_enabled ? {
      directory  = var.wordlist_directory
      host       = local.wordlist_host
      region     = local.wordlist_region
      bucket     = var.wordlist_bucket
      keys       = local.wordlist_keys
      access_key = var.wordlist_access_key
      secret_key = var.wordlist_secret_key
    } : null

    extra_packages = each.value.extra_packages
    extra          = each.value.extra_cloud_init
  })

  # String enum in this provider, not a bool.
  backups = each.value.backups ? "enabled" : "disabled"

  dynamic "backups_schedule" {
    for_each = each.value.backup_schedule == null ? [] : [each.value.backup_schedule]

    content {
      type = backups_schedule.value.type
      hour = backups_schedule.value.hour
      dow  = backups_schedule.value.dow
      dom  = backups_schedule.value.dom
    }
  }

  # These boxes are cattle; skip the per-deploy mail.
  activation_email = false

  # Cross-field rules live here rather than in variable validation because they
  # need the value *after* var.defaults inheritance has been applied.
  lifecycle {
    # Keys are required regardless of user_scheme: the cloud-init template
    # disables password authentication AND root SSH login on first boot, and
    # these keys are what land in the admin user's authorized_keys. No key
    # means the web console is the only way in.
    precondition {
      condition     = length(each.value.ssh_key_names) > 0
      error_message = "Instance \"${each.key}\" has no SSH keys, and cloud-init disables password authentication and root login on first boot -- \"${var.admin_user}\" would be unreachable except through the Vultr web console. Set ssh_key_names in instances.auto.tfvars (globally or on the instance) to a key name from Account -> SSH Keys."
    }

    precondition {
      condition     = each.value.backup_schedule == null || each.value.backups
      error_message = "Instance \"${each.key}\" sets backup_schedule but resolves to backups = false. Set backups = true on the instance, or in var.defaults."
    }

    # The wordlist settings are all-or-nothing. Failing the plan on a partial
    # set beats silently skipping the download and paying for a 32-core box
    # that has nothing to crack against.
    precondition {
      condition     = local.wordlist_enabled || local.wordlist_disabled
      error_message = "The wordlist settings are partially configured. Set all of WORDLIST_DIRECTORY, WORDLIST_ENDPOINT, WORDLIST_BUCKET, WORDLIST_NAMES (repository variables) and WORDLIST_ACCESS_KEY, WORDLIST_SECRET_KEY (repository secrets) -- TF_VAR_wordlist_* locally -- or none of them."
    }

    # "  " is neither empty nor a usable key list, and would otherwise render a
    # fetch script with no objects in it.
    precondition {
      condition     = !local.wordlist_enabled || length(local.wordlist_keys) > 0
      error_message = "WORDLIST_NAMES contains no object keys. Give it a comma- or whitespace-separated list, e.g. \"rockyou.txt.gz, corpora/weakpass_4.txt.gz\"."
    }

    # The fetch script only exists inside the hashcat payload. A single
    # hashcat = false box alongside cracking boxes is fine -- the corpus is not
    # for it -- but a corpus configured for a fleet where *nothing* has hashcat
    # enabled downloads nowhere, and is worth failing on.
    precondition {
      condition     = !local.wordlist_enabled || local.any_hashcat
      error_message = "The WORDLIST_* settings are configured, but no instance has hashcat enabled, so the corpus would never be downloaded. Enable hashcat on at least one instance, or clear the WORDLIST_* settings."
    }

    precondition {
      condition     = !each.value.disable_public_ipv4 || length(each.value.vpc_ids) > 0 || each.value.enable_ipv6
      error_message = "Instance \"${each.key}\" disables public IPv4 without a VPC or IPv6, which would make it unreachable."
    }
  }
}
