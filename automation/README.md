# Automation: a DigitalOcean exit node in one command

Two ways to build the same thing. Both use the same first-boot file, the same policy rules and the same "one-off key" idea. They differ only in how the server gets created.

**Status:** proof of concept, validated offline only (shellcheck, `tofu validate`, the offline dry run). It has not yet been run against a live DigitalOcean account.

| | Shell script + cloud-init | Terraform |
|---|---|---|
| **Needs installing** | Nothing. curl and python3 ship with macOS | OpenTofu or Terraform (`brew install opentofu`) |
| **Tailscale credential** | An auth key you make in the admin console, or an OAuth client | An OAuth client |
| **Good for** | Doing it once and understanding every step | Rebuilding on demand and keeping it in code |
| **Tear down** | `destroy-digitalocean.sh` | `tofu destroy`, then remove the machine from the tailnet |

The rest of this file is the script path. The Terraform path has its own [README](terraform/README.md).

## Before either path: the policy file

This is the step people skip, and it's the one that makes everything unattended.

Open the admin console, go to **Access Controls**, and merge the contents of [`policy/tailnet-policy-snippet.hujson`](policy/tailnet-policy-snippet.hujson) into your policy. In plain terms it says three things: a tag called `tag:exit` exists and admins may hand it out; anything wearing that tag is automatically accepted as an exit node; and you may SSH into tagged machines over the tailnet. Every line in the file has a comment saying why it's there.

**Save it before you create the server.** Auto-approval only applies to machines that register after the rule exists. If the server comes first, it still joins your tailnet, but you'll have to approve it by hand once (Machines → the node → Edit route settings → Use as exit node → Save).

## Path A: the script

### What you need

1. **A DigitalOcean API token.** Control panel → Account → API → Tokens → Generate New Token. Custom scopes are enough: droplet create, read and delete; ssh_key read; region read. Give it a short expiry.
2. **A Tailscale auth key**, one of two ways:
   - *Simple:* admin console → Settings → Keys → Generate auth key. Reusable **off**, Expiration as short as it allows, Ephemeral **off**, Pre-approved **on** (the option only appears when device approval is turned on for your tailnet), Tags **tag:exit**. Copy it once; it's shown once.
   - *Repeatable:* Settings → OAuth clients → Generate. Scope **auth_keys**, tag **tag:exit**. The script then mints a 15-minute single-use key each run.
3. Optionally, an SSH public key on your DigitalOcean account (Settings → Security). Without one, DigitalOcean emails you a root password. It only works in their web console, because the first-boot file turns off password SSH, and you'll be using Tailscale SSH anyway.

Why those key settings matter: **reusable off** means the key dies after one use; **ephemeral off** matters because ephemeral machines are deleted after an hour of silence, which is the opposite of what a server should do; **pre-approved** skips the device-approval queue if you have one; and the **tag** is what triggers auto-approval and also stops the machine's key from expiring after 180 days.

### Run it

Put the secrets in your shell without leaving them in history or on screen. `read -rs` takes the value without echoing it, so only the `read` command itself is recorded. That holds in bash and zsh whatever their history settings, unlike the leading-space trick, which needs `HIST_IGNORE_SPACE` / `HISTCONTROL=ignorespace` and isn't on by default in macOS zsh:

```bash
cd automation/scripts
read -rs DIGITALOCEAN_TOKEN && export DIGITALOCEAN_TOKEN   # paste the dop_v1_... token, Enter
read -rs TS_AUTHKEY && export TS_AUTHKEY                   # paste the tskey-auth-... key, Enter
./provision-digitalocean.sh --name exit-nyc1 --region nyc1 --dry-run
./provision-digitalocean.sh --name exit-nyc1 --region nyc1
```

The dry run prints the exact request it would send (with the first-boot file redacted) and creates nothing. The real run should take about three minutes end to end (an estimate; it has not yet been run live). It finishes by watching your local Tailscale client until the new machine shows up in `tailscale exit-node list`.

Useful flags: `--region` (any DigitalOcean region slug), `--size` (default `s-1vcpu-1gb`, the $6 tier with 1 TB of transfer), `--ssh-key NAME` to attach a specific key, `--no-verify` if this machine isn't on the tailnet. `--help` lists them all.

### What it does, step by step

1. Checks the region exists, the size is offered there, and no droplet already has that name.
2. Looks up your SSH keys (all of them, unless you name one).
3. Takes the auth key from `TS_AUTHKEY`, or mints one through the Tailscale API with your OAuth client.
4. Fills in the first-boot template ([`cloud-init/cloud-init.yaml.tpl`](cloud-init/cloud-init.yaml.tpl)) with the hostname, the tag and the key (base64-encoded, so no character in it can break the file).
5. Sends one request to DigitalOcean: create the droplet with IPv6 on, monitoring on, and that file as its user data.
6. Waits for the droplet to become active, records its id and addresses in `scripts/.state/<name>.json` (no secrets in there), and then waits for the machine to appear as an exit node on your tailnet.

Secrets never touch a command line: the API token goes to curl through a config on standard input, request bodies live in a private scratch folder that's deleted on exit, and the key reaches the template renderer on standard input. On the server, the key sits in a root-only file for a few seconds and that file is shredded right after `tailscale up`. Cloud-init's stored copy of the user data (`/var/lib/cloud/instance/`) and DigitalOcean's metadata service still hold it, but by then it's a spent single-use key. `--render-out` (dry runs only) is the one option that deliberately writes the rendered file, key included, to a path you choose.

### Tear it down

```bash
./destroy-digitalocean.sh --name exit-nyc1                  # delete the droplet
./destroy-digitalocean.sh --name exit-nyc1 --remove-device  # ...and the tailnet machine, via the API
```

The second form needs a Tailscale credential with the **devices:core** scope (an OAuth client bound to `tag:exit`, in `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_CLIENT_SECRET`, or an API key in `TS_API_KEY`). Without it, remove the machine by hand on the Machines page; a dead entry is harmless but untidy. If your Mac is routing through the node at that moment, the script switches the exit node off first so you're not left offline.

Afterwards, revoke the DigitalOcean token and, if you made one, the auth key (Settings → Keys), and `unset DIGITALOCEAN_TOKEN TS_AUTHKEY`.

## The first-boot file

[`cloud-init/cloud-init.yaml.tpl`](cloud-init/cloud-init.yaml.tpl) is shared by both paths and commented line by line. In short: it writes the kernel forwarding settings, a small script for Tailscale's recommended network-card tweak, and the key file; installs Tailscale; runs `tailscale up` exactly once with every flag it needs (tag, exit node, Tailscale SSH, hostname); switches on auto-updates with `tailscale set`; and shreds the key.

It's plain cloud-init, so it works on any provider that accepts user data. Only the "create the server" step is DigitalOcean-specific.

## Troubleshooting

- **The machine joins the tailnet but never becomes an exit node.** The policy was saved after the machine registered, or the tag didn't get applied. Approve it once by hand (Machines → node → Edit route settings → Use as exit node → Save), and check the node shows `tag:exit` on the Machines page. If it doesn't, the auth key wasn't tagged; make a new key and rebuild.
- **The machine never joins.** The auth key had expired or was rejected, or first boot failed. Look at the server: `ssh root@<ip> 'cloud-init status --wait; tail -50 /var/log/cloud-init-output.log'`.
- **DigitalOcean answers 422.** The message says why: usually a size that isn't offered in that region, or IPv6 not available there. The dry run shows the request; `--size` and `--region` change it.
- **The script says there's no connected Tailscale client.** It can't do the final check, so it prints how to check by hand. The droplet is fine.
- **You got an email with a root password.** No SSH key was attached. The password works in DigitalOcean's web console only. Use Tailscale SSH (`ssh root@exit-nyc1`) for everyday access.
- **IPv6 through the exit node doesn't work.** The droplet was created without IPv6. The script always asks for it; if you made the droplet another way, enable IPv6 on it in the DigitalOcean console and reboot.

Run [`scripts/validate-local.sh`](scripts/validate-local.sh) after editing anything here. It checks the scripts, renders the template with a fake key, parses the result, and validates the policy files and the Terraform module, all without touching a cloud account.
