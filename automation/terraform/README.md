# Path B: Terraform

The same exit node as the script path, as code. One `apply` writes an optional policy, mints a single-use auth key, and creates the droplet with the shared first-boot file.

## Prerequisites

- OpenTofu (`brew install opentofu`) or Terraform 1.6 or newer. The commands below say `tofu`; `terraform` works the same.
- A DigitalOcean API token (droplet create/read/delete, ssh_key read).
- A Tailscale OAuth client (admin console → Settings → OAuth clients) with the **auth_keys** scope, bound to **tag:exit**. Add **policy_file** write only if you set `manage_acl = true`, and **devices:core** read only if you set `wait_for_device = true`.

## Environment variables

Credentials never go in `.tf` or `.tfvars` files:

```bash
read -rs DIGITALOCEAN_TOKEN && export DIGITALOCEAN_TOKEN                        # paste, Enter
read -rs TAILSCALE_OAUTH_CLIENT_ID && export TAILSCALE_OAUTH_CLIENT_ID          # paste, Enter
read -rs TAILSCALE_OAUTH_CLIENT_SECRET && export TAILSCALE_OAUTH_CLIENT_SECRET  # paste the tskey-client-... secret, Enter
```

(`TAILSCALE_API_KEY` works instead of the OAuth pair. `read -rs` doesn't echo the value, so it stays off the screen and out of your shell history.)

## The policy comes first

`manage_acl` is **false** by default, and you should probably leave it that way. When it's true, Terraform writes `../policy/tailnet-policy-full-example.hujson` (or whatever you pass in `acl_policy`) as your **entire** tailnet policy, replacing every rule you have today. That's fine for a fresh tailnet you own; it's a bad surprise anywhere else.

The safe path is the same as for the script: merge [`../policy/tailnet-policy-snippet.hujson`](../policy/tailnet-policy-snippet.hujson) into your policy in the admin console before you apply. The key resource depends on the policy resource even when that resource is switched off, so ordering is right in both cases.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars   # edit name, region, size
tofu init
tofu plan
tofu apply
```

Outputs give you the droplet id and addresses, the tailnet hostname, the id of the auth key (so you can revoke it) and the commands to try the exit node from a device.

## Rebuilding

The auth key only matters on first boot, and it goes into the droplet's `user_data`. DigitalOcean replaces a droplet whenever `user_data` changes, so the module tells Terraform to ignore changes to it after creation. That means a later `apply` won't touch a working node just because the key expired. To rebuild on purpose:

```bash
tofu apply -replace=tailscale_tailnet_key.exit -replace=digitalocean_droplet.exit
```

The key resource keeps the provider's default for `recreate_if_invalid` (single-use keys are not recreated), which keeps plans quiet once the key has been consumed.

## Destroy

```bash
tofu destroy
```

That deletes the droplet and the (already spent) key. It does **not** remove the machine from your tailnet; do that on the Machines page, or with the script:

```bash
../scripts/destroy-digitalocean.sh --name exit-nyc1 --device-only --remove-device
```

## About the state file

`terraform.tfstate` contains the auth key in cleartext. That's why the key is single-use, pre-approved and expires after 15 minutes by default: by the time anyone could read the state, the key is useless. Keep the state local (the module has no remote backend) and out of version control (the project `.gitignore` already covers it).

## Validating without a cloud account

```bash
tofu fmt -check
tofu init -backend=false
tofu validate
```

[`../scripts/validate-local.sh`](../scripts/validate-local.sh) runs these along with everything else.
