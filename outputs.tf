output "instances" {
  description = "Per-instance summary, keyed by the same name used as the workflow `instance` input."

  value = {
    for k, r in vultr_instance.this : k => {
      id            = r.id
      label         = r.label
      hostname      = r.hostname
      region        = r.region
      plan          = r.plan
      os            = r.os
      vcpu_count    = r.vcpu_count
      ram_mb        = r.ram
      disk          = r.disk
      main_ip       = r.main_ip
      v6_main_ip    = r.v6_main_ip
      internal_ip   = r.internal_ip
      status        = r.status
      power_status  = r.power_status
      server_status = r.server_status
      tags          = r.tags
      date_created  = r.date_created
    }
  }
}

output "ssh" {
  description = "Ready-to-paste SSH commands. Cloud-init disables root SSH login, so these use the admin user."

  value = {
    for k, r in vultr_instance.this : k =>
    format(
      "ssh %s@%s",
      var.admin_user,
      r.main_ip != "" ? r.main_ip : r.v6_main_ip,
    )
    if !local.effective[k].vpc_only
  }
}

output "dns_records" {
  description = <<-EOT
    The A/AAAA records these instances expect to exist, keyed by hostname then
    record type. scripts/dns-sync.sh reconciles this map against Cloudflare --
    the apply and destroy workflows run it automatically when the
    CLOUDFLARE_API_TOKEN secret is set, and `make dns` runs the same sync
    locally. A hostname mapping to an empty object means "this instance wants
    no public records", which is what lets the prune retire them.
  EOT

  value = {
    for k, r in vultr_instance.this : r.hostname => {
      for t, ip in { A = r.main_ip, AAAA = r.v6_main_ip } : t => ip
      if ip != ""
    }
  }
}

output "inventory" {
  description = "Machine-readable id/ip map consumed by scripts/diagnose.sh."

  value = {
    for k, r in vultr_instance.this : k => {
      id      = r.id
      main_ip = r.main_ip
      v6_ip   = r.v6_main_ip
      label   = r.label
    }
  }
}

output "default_passwords" {
  description = "Vultr-generated default passwords. Only meaningful until you disable password auth."
  sensitive   = true

  value = {
    for k, r in vultr_instance.this : k => r.default_password
  }
}
