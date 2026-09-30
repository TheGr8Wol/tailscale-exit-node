# Credentials come from the environment, so nothing secret ever lands in a
# .tf or .tfvars file:
#
#   DIGITALOCEAN_TOKEN               DigitalOcean API token
#   TAILSCALE_OAUTH_CLIENT_ID        OAuth client with the auth_keys scope, bound
#   TAILSCALE_OAUTH_CLIENT_SECRET    to tag:exit (plus policy_file if manage_acl,
#                                    devices:core read if wait_for_device)
#   TAILSCALE_API_KEY                alternative to the OAuth pair
#
# var.tailnet defaults to "-", which means "the tailnet that owns the credential".

provider "digitalocean" {}

provider "tailscale" {
  tailnet = var.tailnet
}
