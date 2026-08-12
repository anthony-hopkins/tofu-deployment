locals {
  # Fully resolved per-instance settings, with var.defaults inheritance and the
  # naming rules already applied.
  #
  # Deliberately contains no data-source references. data.tf keys its OS and
  # SSH-key lookups off this map, and main.tf layers the resolved IDs back on
  # top -- if the resolved IDs lived here that would be a dependency cycle.
  effective = {
    for name, cfg in var.instances : name => {
      # --- placement -------------------------------------------------------
      plan   = coalesce(cfg.plan, var.defaults.plan)
      region = coalesce(cfg.region, var.defaults.region)

      # --- image -----------------------------------------------------------
      os_name     = coalesce(cfg.os_name, var.defaults.os_name)
      snapshot_id = cfg.snapshot_id

      # --- naming ----------------------------------------------------------
      # "lab01.dhs-labs.us", or "containerlabs-lab01" when dns_zone is empty.
      fqdn  = coalesce(cfg.hostname, local.default_name[name])
      label = coalesce(cfg.label, local.default_name[name])

      # cloud-init wants the short name in `hostname` and the full name in
      # `fqdn`; handing it an FQDN for both produces a host called
      # "lab01.dhs-labs.us" with a trailing-dot mess in /etc/hosts.
      short_hostname = split(".", coalesce(cfg.hostname, local.default_name[name]))[0]

      # `instance:<key>` is what scripts/lib.sh resolves a machine by, so the
      # label is free to be anything without breaking the tooling.
      tags = distinct(concat(
        [var.project, "managed-by:opentofu", "instance:${name}"],
        cfg.tags,
      ))

      # --- access ----------------------------------------------------------
      user_scheme       = coalesce(cfg.user_scheme, var.defaults.user_scheme)
      ssh_key_names     = cfg.ssh_key_names == null ? var.ssh_key_names : cfg.ssh_key_names
      firewall_group_id = cfg.firewall_group_id

      # --- networking ------------------------------------------------------
      # Explicit null tests rather than coalesce: a deliberate `false` must
      # win over a `true` default, and that reads clearer spelled out.
      enable_ipv6         = cfg.enable_ipv6 == null ? var.defaults.enable_ipv6 : cfg.enable_ipv6
      disable_public_ipv4 = cfg.disable_public_ipv4
      ddos_protection     = cfg.ddos_protection
      vpc_ids             = cfg.vpc_ids
      vpc_only            = cfg.vpc_only

      # --- backups ---------------------------------------------------------
      backups         = cfg.backups == null ? var.defaults.backups : cfg.backups
      backup_schedule = cfg.backup_schedule

      # --- lab payload -----------------------------------------------------
      docker           = cfg.docker == null ? var.defaults.docker : cfg.docker
      extra_packages   = cfg.extra_packages
      extra_cloud_init = cfg.extra_cloud_init
    }
  }

  default_name = {
    for name, _ in var.instances : name =>
    var.dns_zone == "" ? "${var.project}-${name}" : "${name}.${var.dns_zone}"
  }

  # --- cEOS lab image ---------------------------------------------------------
  # img_enabled/img_disabled feed the all-or-nothing precondition in main.tf;
  # only img_enabled turns the download on in the cloud-init template.
  img_settings = {
    IMG_DIRECTORY  = var.img_directory
    IMG_ENDPOINT   = var.img_endpoint
    IMG_BUCKET     = var.img_bucket
    IMG_NAME       = var.img_name
    IMG_ACCESS_KEY = var.img_access_key
    IMG_SECRET_KEY = var.img_secret_key
  }

  img_enabled  = alltrue([for v in values(local.img_settings) : v != ""])
  img_disabled = alltrue([for v in values(local.img_settings) : v == ""])

  # The README documents TFSTATE_ENDPOINT with its https:// scheme, so accept
  # the same shape here. curl needs the bare host, and its --aws-sigv4 signing
  # region is the endpoint's first DNS label (ewr1.vultrobjects.com -> ewr1).
  img_host   = trimsuffix(trimprefix(trimprefix(var.img_endpoint, "https://"), "http://"), "/")
  img_region = split(".", local.img_host)[0]

  # Distinct lookups only: an OS or key shared by ten instances is fetched once.
  os_names = toset([
    for name, e in local.effective : e.os_name
    if e.snapshot_id == null
  ])

  ssh_key_names = toset(flatten([
    for name, e in local.effective : e.ssh_key_names
  ]))
}
