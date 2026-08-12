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
    docker       = each.value.docker

    # Vultr only injects ssh_key_ids into root/linuxuser, so the admin user
    # gets the same public keys planted via cloud-init.
    admin_user      = var.admin_user
    ssh_public_keys = [for n in each.value.ssh_key_names : trimspace(data.vultr_ssh_key.this[n].ssh_key)]

    # null when the IMG_* variables are unset; the template then renders no
    # image directory, download script or docker import.
    img = local.img_enabled ? {
      directory  = var.img_directory
      host       = local.img_host
      region     = local.img_region
      bucket     = var.img_bucket
      name       = var.img_name
      version    = local.img_version
      access_key = var.img_access_key
      secret_key = var.img_secret_key
    } : null

    course_repo = var.course_repo

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

  # These labs are cattle; skip the per-deploy mail.
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

    # The cEOS image settings are all-or-nothing. Failing the plan on a
    # partial set beats silently skipping the download and shipping labs
    # without their image.
    precondition {
      condition     = local.img_enabled || local.img_disabled
      error_message = "The cEOS image settings are partially configured. Set all of IMG_DIRECTORY, IMG_ENDPOINT, IMG_BUCKET, IMG_NAME (repository variables) and IMG_ACCESS_KEY, IMG_SECRET_KEY (repository secrets) -- TF_VAR_img_* locally -- or none of them."
    }

    precondition {
      condition     = !each.value.disable_public_ipv4 || length(each.value.vpc_ids) > 0 || each.value.enable_ipv6
      error_message = "Instance \"${each.key}\" disables public IPv4 without a VPC or IPv6, which would make it unreachable."
    }
  }
}
