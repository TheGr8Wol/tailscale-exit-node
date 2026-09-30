# One DigitalOcean droplet that boots straight into being a Tailscale exit node.
#
# Order of operations, and why it matters:
#   1. (optional) the tailnet policy, so the tag and the auto-approval rule exist
#   2. a one-off, pre-approved, tagged auth key
#   3. the droplet, with the key baked into its first-boot cloud-init file
# If the policy landed after the node registered, the node would join but never
# be approved as an exit node, so the key depends on the policy resource even
# when that resource is switched off.

locals {
  template_path = coalesce(var.cloud_init_template_path, "${path.module}/../cloud-init/cloud-init.yaml.tpl")
  acl_policy    = var.acl_policy != null ? var.acl_policy : file("${path.module}/../policy/tailnet-policy-full-example.hujson")

  ssh_key_ids = var.no_ssh_keys ? [] : (
    length(var.ssh_key_ids) > 0
    ? var.ssh_key_ids
    : [for k in data.digitalocean_ssh_keys.all[0].ssh_keys : tostring(k.id)]
  )
}

# Off by default: this replaces the WHOLE policy file, not just the keys we need.
resource "tailscale_acl" "this" {
  count = var.manage_acl ? 1 : 0

  acl                        = local.acl_policy
  overwrite_existing_content = true
  reset_acl_on_destroy       = false
}

# Single use, not ephemeral (ephemeral nodes vanish after an hour idle), already
# approved, tagged so it self-approves as an exit node and never has its node
# key expire. recreate_if_invalid is left at the provider default on purpose:
# a consumed single-use key would otherwise churn every plan.
resource "tailscale_tailnet_key" "exit" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = var.auth_key_expiry_seconds
  tags          = [var.tailscale_tag]
  description   = "exit node ${var.name} (terraform)"

  depends_on = [tailscale_acl.this]
}

data "digitalocean_ssh_keys" "all" {
  count = length(var.ssh_key_ids) == 0 && !var.no_ssh_keys ? 1 : 0
}

resource "digitalocean_droplet" "exit" {
  name       = var.name
  region     = var.region
  size       = var.size
  image      = var.image
  ipv6       = true
  monitoring = true
  tags       = var.droplet_tags
  ssh_keys   = local.ssh_key_ids

  user_data = templatefile(local.template_path, {
    hostname    = var.name
    ts_tag      = var.tailscale_tag
    authkey_b64 = base64encode(tailscale_tailnet_key.exit.key)
  })

  # A new key means new user_data, and DigitalOcean replaces the droplet when
  # user_data changes. The key only matters on first boot, so ignore it after
  # that. To rebuild on purpose:
  #   tofu apply -replace=tailscale_tailnet_key.exit -replace=digitalocean_droplet.exit
  lifecycle {
    ignore_changes = [user_data]
  }
}

# Optional: block until the machine shows up on the tailnet, which also gives
# you its full MagicDNS name in the outputs.
data "tailscale_device" "exit" {
  count = var.wait_for_device ? 1 : 0

  hostname = var.name
  wait_for = "180s" # a literal on purpose: the provider rejects an unknown variable during validate

  depends_on = [digitalocean_droplet.exit]
}
