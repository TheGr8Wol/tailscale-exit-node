# Runbook: setting up both exit nodes on your tailnet

This is the live, do-it-together version of the guide: a human operator and an AI coding assistant working through it side by side. It assumes one setup: a tailnet with a Mac (called `my-mac` below) and a phone on it, with MagicDNS switched on. Mullvad comes first because it's quick; the DigitalOcean server second because it needs a policy edit and two credentials.

Every step is labelled:

- **[You]** something only you can do: a purchase, a token, a click that changes your account.
- **[Assistant]** something the assistant runs on this Mac. Everything it runs is read-only except the two places marked, where it switches this Mac's exit node on or off, and only after you say go.
- **[Checkpoint]** how we both know the step worked.

**Ground rules.** You handle checkout and billing. You create API tokens and auth keys, type them into your own terminal with `read -rs` (so they're never echoed), and never paste them into the conversation; that way the assistant never sees them. You run the command that creates the server. If anything below feels off, stop and ask.

---

## Phase 0: preflight

**[You]** Turn Tailscale on. Click the Tailscale icon in the menu bar and choose **Connect**, if it isn't already connected.

**[Assistant]** Confirms the client is up:

```bash
tailscale status
tailscale exit-node list       # expect "no exit nodes found" at this point
```

**[Checkpoint]** `tailscale status` lists `my-mac` and the phone, and doesn't say "Tailscale is stopped".

**[You]** Make sure you can open the admin console at <https://console.tailscale.com/admin/machines> as the tailnet owner. Everything from here on assumes that.

---

## Phase 1: Mullvad

**[You]** In the admin console: **Settings → General**, scroll to **Mullvad VPN**, select **Configure**, and go through the checkout. On the free Personal plan you can choose monthly or annual. It's $5 a month for a pack of 5 device licences.

**[You]** Back in **Configure**, choose **Add devices**, tick `my-mac` (and the phone if you want it), and save.

**[Assistant]** Watches for the servers to appear. The first sync can take up to two minutes:

```bash
tailscale exit-node list | head
tailscale exit-node suggest
```

**[Checkpoint]** The list shows entries ending in `mullvad.ts.net`, and `suggest` names one.

**[You]** Pick a country from the menu bar: Tailscale → **Exit Nodes → Location Based Exit Nodes → Countries**. Or say the word and the assistant does it from the command line:

**[Assistant, changes this Mac's routing, only on your go]**

```bash
tailscale set --exit-node=<the suggested host> --exit-node-allow-lan-access=true
```

**[Checkpoint]**

```bash
curl -4 https://am.i.mullvad.net/connected     # "You are connected to Mullvad..."
curl -4 https://ifconfig.me                    # not your home address
```

**[Assistant, changes this Mac's routing]** Switches it back off:

```bash
tailscale set --exit-node=
curl -4 https://ifconfig.me                    # home address again
```

**[You, optional]** On the phone (iOS shown): Tailscale app → **Exit Nodes → Location Based**.

---

## Phase 2: the policy file (before the server exists)

This is the step that makes the server approve itself. It has to be saved before the server boots.

**[Assistant]** Opens `automation/policy/tailnet-policy-snippet.hujson` and explains what each key does. In short: a tag `tag:exit` that admins may hand out; a rule that anything wearing it is automatically accepted as an exit node; permission for your devices to reach it; and Tailscale SSH into it.

**[You]** Admin console → **Access Controls**. Merge the snippet's keys into your policy. If your policy is still the default one, that means adding the `tagOwners`, `autoApprovers` and `ssh` blocks alongside the existing rules (the default allow-all rule already covers network access). Select **Save**. The editor checks the syntax before it saves.

**[Checkpoint]** The save succeeds, and on the next screen (Keys) `tag:exit` is offered in the tag picker.

---

## Phase 3: credentials (you only)

**[You]** Tailscale auth key: **Settings → Keys → Generate auth key**.
- Reusable: **off**
- Expiration: **1 day** (the minimum)
- Ephemeral: **off**
- Pre-approved: **on** (this option only appears if device approval is turned on for your tailnet; if you don't see it, that's fine)
- Tags: **tag:exit**

Copy it once; it's shown once. It starts with `tskey-auth-`.

**[You]** DigitalOcean token: log in, then **Account → API → Tokens → Generate New Token**. Choose custom scopes: `droplet` create, read, delete; `ssh_key` read; `region` read. Set the shortest expiry that fits. Copy it once. It starts with `dop_v1_`.

**[You, optional but recommended]** Add an SSH public key to DigitalOcean (**Settings → Security → Add SSH key**). Without one, DigitalOcean emails you a root password that only works in their web console. If this Mac has no SSH key yet, `ssh-keygen -t ed25519` makes one, and the public half is in `~/.ssh/id_ed25519.pub`. Tailscale SSH will handle day-to-day access either way.

---

## Phase 4: create the server (your terminal)

**[You]** In your own terminal. Enter the two secrets with `read -rs`: paste each one when the cursor waits and press Enter. Nothing is echoed, so the values never show on screen or land in shell history:

```bash
cd automation/scripts            # from the repository root
read -rs DIGITALOCEAN_TOKEN && export DIGITALOCEAN_TOKEN   # paste the dop_v1_... token, Enter
read -rs TS_AUTHKEY && export TS_AUTHKEY                   # paste the tskey-auth-... key, Enter
./provision-digitalocean.sh --name exit-nyc1 --region nyc1 --dry-run
```

**[Checkpoint]** The dry run prints the request it would send. Region, size and name look right, `"ipv6": true`, and it says "nothing was created".

**[You]** Now for real:

```bash
./provision-digitalocean.sh --name exit-nyc1 --region nyc1
```

It creates the droplet, waits for it to come up (expect about a minute), then watches this Mac's tailnet until `exit-nyc1` shows up as an exit node (expect another minute or two while cloud-init installs Tailscale). These timings are estimates; this runbook is the first live test of the automation.

**[You]** Copy the non-secret output (droplet id, addresses, the final message) and paste it to the assistant. Don't hand over the whole terminal; you choose what the assistant sees.

Pick a different `--region` if you'd rather the exit be somewhere else; `nyc1` is just a default. Any DigitalOcean region slug works.

---

## Phase 5: verify from this Mac

**[Assistant]**

```bash
tailscale exit-node list          # exit-nyc1 is listed
tailscale status | grep exit-nyc1 # online, tagged
```

**[Assistant, changes this Mac's routing, only on your go]**

```bash
tailscale set --exit-node=exit-nyc1 --exit-node-allow-lan-access=true
```

**[Checkpoint]**

```bash
curl -4 https://ifconfig.me       # the droplet's IPv4
curl -6 https://ifconfig.me       # the droplet's IPv6
dig +short tailscale.com          # DNS still resolves
```

**[Assistant, changes this Mac's routing]** Back to normal:

```bash
tailscale set --exit-node=
```

**[Assistant, optional]** A look inside the server over Tailscale SSH, to confirm forwarding and the performance tweak took:

```bash
ssh root@exit-nyc1 'tailscale status | head -3; sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding; ethtool -k eth0 | grep -E "rx-udp-gro-forwarding|rx-gro-list"; cloud-init status'
```

**[You]** Admin console → **Machines**, filter `property:exit-node`. `exit-nyc1` is there with `tag:exit`, key expiry disabled, and "Exit node" shown.

---

## Phase 6 (optional): the Terraform path

Same result, as code. **[You]** create an OAuth client (**Settings → OAuth clients**) with the `auth_keys` scope and tag `tag:exit`, enter `TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET` the same way as in Phase 4 (`read -rs`, then `export`) alongside `DIGITALOCEAN_TOKEN`, then in `automation/terraform`: `tofu init && tofu apply`. Use a different `name` than Phase 4 so the two don't collide. Verify exactly as in Phase 5. Details in [automation/terraform/README.md](automation/terraform/README.md).

---

## Phase 7: tear down (when you're done experimenting)

**[You]**

```bash
cd automation/scripts            # from the repository root
./destroy-digitalocean.sh --name exit-nyc1
```

It shows the droplet, asks once, switches this Mac's exit node off if it's still using it, and deletes the droplet. Then remove the machine from the tailnet: **Machines → exit-nyc1 → Remove** (or rerun with `--remove-device` and an OAuth client that has `devices:core`).

**[You]** Revoke the DigitalOcean token (Account → API) and the auth key (Settings → Keys), and clear them from the shell: `unset DIGITALOCEAN_TOKEN TS_AUTHKEY`.

**[Checkpoint]** `tailscale exit-node list` no longer shows `exit-nyc1`; the DigitalOcean Droplets page is empty; the bill shows minutes, not months.

The Mullvad add-on keeps billing until you remove it: **Settings → Billing → Manage add-ons → Mullvad VPN → Remove add-on**.
