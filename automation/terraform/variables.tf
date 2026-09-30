variable "name" {
  description = "Droplet name and tailnet hostname. Lowercase letters, digits and dashes only."
  type        = string
  default     = "ts-exit-nyc1"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.name))
    error_message = "Use lowercase letters, digits and dashes only, at most 63 characters."
  }
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "nyc1"
}

variable "size" {
  description = "Droplet size slug. s-1vcpu-1gb is about $6/month with 1 TB of transfer, which suits an exit node better than the $4 tier's 500 GB."
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "image" {
  description = "Droplet image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "tailscale_tag" {
  description = "Tag the node joins with. Must exist in tagOwners and be listed under autoApprovers.exitNode in your policy."
  type        = string
  default     = "tag:exit"

  validation {
    condition     = startswith(var.tailscale_tag, "tag:") && length(var.tailscale_tag) > 4
    error_message = "The tag must look like tag:something."
  }
}

variable "droplet_tags" {
  description = "DigitalOcean tags put on the droplet."
  type        = list(string)
  default     = ["tailscale-exit"]
}

variable "ssh_key_ids" {
  description = "DigitalOcean SSH key ids to attach. Empty means every key on the account."
  type        = list(string)
  default     = []
}

variable "no_ssh_keys" {
  description = "Attach no SSH key at all. DigitalOcean then emails a root password that only works in their web console, since cloud-init disables password SSH."
  type        = bool
  default     = false
}

variable "auth_key_expiry_seconds" {
  description = "How long the one-off auth key stays valid. It only has to survive until the droplet's first boot, so keep it short: the key sits in Terraform state in cleartext."
  type        = number
  default     = 900

  validation {
    condition     = var.auth_key_expiry_seconds >= 300 && var.auth_key_expiry_seconds <= 7776000
    error_message = "Between 300 seconds (5 minutes) and 7776000 seconds (90 days)."
  }
}

variable "manage_acl" {
  description = "Let Terraform write the tailnet policy file. WARNING: this REPLACES your entire policy with acl_policy (or the bundled full example). Leave false and merge the snippet by hand unless this tailnet is yours to overwrite."
  type        = bool
  default     = false
}

variable "acl_policy" {
  description = "Complete policy file (HuJSON string) to apply when manage_acl is true. Defaults to ../policy/tailnet-policy-full-example.hujson."
  type        = string
  default     = null
}

variable "cloud_init_template_path" {
  description = "Path to the cloud-init template. Defaults to the shared ../cloud-init/cloud-init.yaml.tpl."
  type        = string
  default     = null
}

variable "wait_for_device" {
  description = "After creating the droplet, wait for the machine to appear on the tailnet and expose its full name. Needs a credential with devices:core read."
  type        = bool
  default     = false
}

variable "tailnet" {
  description = "Tailnet name for the Tailscale provider. \"-\" means the tailnet that owns the credential."
  type        = string
  default     = "-"
}
