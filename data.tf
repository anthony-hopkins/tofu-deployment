# Name -> ID lookups. Both fail at plan time if the name does not exist in the
# account, which is the point: a typo should not survive to become an instance
# you cannot log into or an image you did not mean to deploy.

data "vultr_os" "this" {
  for_each = local.os_names

  filter {
    name   = "name"
    values = [each.value]
  }
}

data "vultr_ssh_key" "this" {
  for_each = local.ssh_key_names

  filter {
    name   = "name"
    values = [each.value]
  }
}
