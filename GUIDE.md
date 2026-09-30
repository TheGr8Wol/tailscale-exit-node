# Tailscale exit nodes: Mullvad, or a cloud server you run yourself

*Reviewed and corrected against Tailscale's documentation on 8 September 2026. This started life as a short two-method guide ("Tailscale: Integrating Commercial VPN Capabilities") that had the right idea and a number of wrong details. That original carried no byline and its source wasn't recorded, so it isn't reproduced here; "the original" below refers to it, and only the specific claims being corrected are quoted. The checking was done by an AI coding agent working under the author's direction, and the author reviewed the results. The fixes are called out inline as **Correction** notes and collected in the [corrections log](#6-corrections-log) at the end.*

## 0. About this guide

You have a Tailscale network (Tailscale calls it a *tailnet*) and you'd like some of your devices to send their internet traffic out through somewhere else: a different country, a fixed IP address, or just not the coffee-shop Wi-Fi. The machine that does this is an **exit node**. This guide covers the two ways to get one without buying hardware:

1. **Mullvad**: rent access to Mullvad's VPN servers as exit nodes, through a Tailscale add-on.
2. **Your own VPS**: rent a small Linux server from a cloud provider and make it an exit node yourself.

Everything here was checked against the current Tailscale docs; the sources are listed in [section 7](#7-sources). Commands are exact and safe to copy. The explanations are deliberately plain.

Three kinds of note appear along the way:

- **Correction**: something the original document got wrong.
- **Heads-up**: a gotcha that catches people.
- **Do this**: a step to take.

## 1. What an exit node actually does

### 1.1 The path a packet takes

Normally, when your laptop asks for a web page, the request leaves through whatever network you're on, and the website sees that network's public IP address. With an exit node selected, Tailscale wraps the request in an encrypted **WireGuard** tunnel (WireGuard is the fast, modern VPN protocol Tailscale is built on) and sends it to the exit node instead. The exit node unwraps it, swaps the sender address for its own (that swap is **NAT**, network address translation), and sends it on its way. The website sees the exit node's IP, and the reply comes back through the same tunnel.

Two things follow from that. The exit node can see where your traffic is going (though not inside HTTPS), so it should be a machine you trust. And whoever the exit node's IP address belongs to is who the internet thinks you are.

For what it's worth, Tailscale keeps destination logging switched off for traffic that passes through exit nodes, on every tailnet, by default.

### 1.2 What stays the same

Traffic to other devices on your tailnet does not go through the exit node. Tailscale still connects those directly, peer to peer. Your home server keeps working exactly as before while your browser goes out through Sweden.

**Heads-up:** by default an exit node also swallows traffic to your *local* network (the printer, the NAS on your LAN). Every client has an "Allow local network access" switch for that. It comes up again in the per-platform sections.

### 1.3 DNS

Nothing to configure. Tailscale clients from version 1.48.3 onward handle DNS correctly with exit nodes, Mullvad ones included.

## 2. Comparison

| | Mullvad add-on | Your own cloud server (VPS) |
|---|---|---|
| **What you pay** | $5/month per 5 devices, on your Tailscale bill | About $4 to $6/month for the server, plus traffic beyond the included allowance |
| **Setup effort** | Buy the add-on, authorise each device, pick a location on each device. Not one click, but no server work | Create a server, run a handful of commands (or the automation in this project), approve it once or add a policy rule |
| **IP address** | Shared with other Mullvad users; changes when you change location | Yours alone, fixed for as long as the server lives |
| **Locations** | 50 countries, 91 cities on Mullvad's current list (it moves) | Wherever your cloud provider has a data centre |
| **Who can see what** | Tailscale knows which of your devices use which Mullvad server (unless client logging is off). Nobody can read the traffic. Mullvad doesn't learn who you are | The cloud provider bills you, so the IP is tied to you. Traffic stays encrypted to the server, then leaves as ordinary internet traffic |
| **Streaming sites and CAPTCHAs** | Mixed. Shared VPN ranges are often blocked or challenged | Mixed. Data-centre ranges are often blocked or challenged too; a dedicated IP only means nobody *else* is spoiling its reputation |
| **Maintenance** | None | A little. Tailscale updates itself and Ubuntu patches itself; you keep an eye on the bill |
| **Device limits** | Licences come in packs of 5 | None beyond what the server can push |
| **Node key expiry** | Not your problem | Relevant: tag the server or disable key expiry, or it silently drops off the tailnet after 180 days |

## 3. Part 1: Mullvad exit nodes

Mullvad is a commercial VPN provider with a good privacy reputation. Tailscale's add-on lets their servers show up in your exit-node list as if they were your own machines, so you don't have to run Mullvad's app alongside Tailscale (which used to fight over routing).

**Heads-up:** Tailscale still labels this feature **beta**.

### 3.1 How it really works

**Correction:** the original described "an isolated Mullvad tailnet" that gets "peered" with yours. That's not how it works, and Tailscale never describes it that way.

What actually happens: each of your devices already has a WireGuard key pair. When you authorise a device for Mullvad, Tailscale registers that existing key with Mullvad's infrastructure, and Tailscale's control plane adds the Mullvad servers to that device's map of the network (they show up with names ending in `mullvad.ts.net`). When you pick one, your device opens a WireGuard tunnel straight to that Mullvad server. Tailscale is the coordinator, not a hop in the path.

The part the original got right: traffic to your own tailnet devices stays peer to peer, and only internet-bound traffic goes to Mullvad.

### 3.2 Before you buy

- **Price:** $5 per month for every 5 devices. Your monthly Tailscale bill changes as you add or remove devices.
- **Plans:** the free Personal plan and the GitHub Community plan can buy it monthly or annually. Standard and Premium plans, monthly only. Enterprise customers go through their account team.
- **Where:** it can't be bought or used in some countries and regions.
- **Doesn't work with:** custom DERP relay servers, or groups synced from Google Workspace. If you use Tailnet Lock, each Mullvad node has to be signed before it can be used.
- **If you already run Mullvad's own app:** turn it off first, including its "Block connections without VPN" setting, or the two will fight.
- **Windows:** the Windows app can't display the full list of Mullvad servers. Use the command line there (`tailscale exit-node list`).

### 3.3 Buying it

**Do this:**

1. Open the admin console at `https://console.tailscale.com/admin/settings/general` (the old `login.tailscale.com` address still redirects there).
2. Scroll down to the **Mullvad VPN** section.
3. Select **Configure** and go through the checkout.

**Correction:** the original said to click **Manage**. The button on the General settings page is **Configure**. "Manage add-ons" exists, but it lives on the Billing page and is for removing the add-on or buying more licences later.

### 3.4 Authorising devices

**Correction:** the original stopped at "activate the add-on", and its comparison table called the whole thing "1 click". Buying the add-on doesn't give any device access. You have to say which devices get it, and each device then has to pick a Mullvad exit node itself.

**Do this** (admin console method):

1. General settings → **Mullvad VPN** → **Configure**.
2. **Add devices**, tick the devices that should be allowed to use Mullvad, and save.

Or use the policy file instead. Give a user or group the `mullvad` node attribute:

```jsonc
"nodeAttrs": [
  {"target": ["you@example.com"], "attr": ["mullvad"]},
]
```

Two rules: you can't mix the two methods, and if the policy grants more devices than you have licences, Tailscale hands licences out to devices in the order they connect to the tailnet, not in the order they try to use Mullvad.

### 3.5 Using it, per platform

The first time a device uses Mullvad (or after a few weeks away) it can take up to two minutes for the server list to sync. That delay looks like a failure; it isn't.

- **macOS:** Tailscale menu → **Exit Nodes** → **Location Based Exit Nodes** → **Countries**, then pick one.
- **Windows:** Tailscale menu → **Exit Nodes** → **Location Based Exit Nodes** → **Location Based**. Remember the full list only shows in the CLI.
- **iOS / iPadOS:** **Exit Nodes** → **Location Based**.
- **Android:** menu → **Use exit node**, then choose. There's an **Allow LAN access** toggle next to it.
- **Apple TV:** supported; it lives in the same exit-node settings.
- **Linux (and any CLI):**

  ```bash
  tailscale exit-node list --filter=Sweden
  sudo tailscale set --exit-node=se-sto-wg-001.mullvad.ts.net --exit-node-allow-lan-access=true
  ```

  `tailscale exit-node suggest` picks a nearby one for you, and `--exit-node=auto:any` follows that suggestion automatically. Server names follow a country-city pattern like the one above; the list command shows the real names.

To stop: choose **None** in the menu, or `sudo tailscale set --exit-node=`.

### 3.6 Privacy, honestly

**Correction:** the original rated Mullvad's anonymity "High (shared IP with thousands)". The shared IP part is true. The anonymity part is misleading, and Tailscale's own documentation is blunt about why.

- Tailscale creates and holds the Mullvad account on your behalf. Tailscale knows which Mullvad accounts belong to which Tailscale users, and Tailscale users are always tied to an email or GitHub identity. There is no anonymous tailnet.
- Tailscale can see, from its logs, which of your devices connected to which Mullvad server. If you turn off client logging on a device, it loses that visibility.
- What Tailscale cannot do is read your traffic. It's encrypted end to end in WireGuard and Tailscale is not in the path.
- Mullvad receives no identity information from Tailscale.

So: websites see a shared Mullvad IP, but you have given up the one thing Mullvad is famous for, the anonymous, no-account signup. If that's the property you need, buy Mullvad directly instead.

### 3.7 Locations

**Correction:** "40+ countries" came from Tailscale's 2023 launch post. Tailscale's docs no longer give a number and point at Mullvad's server list, which currently shows 50 countries, 91 cities and 569 servers. Expect it to keep changing.

### 3.8 Troubleshooting

- **No Mullvad entries in the list:** wait the two minutes, then check the device is actually authorised (3.4). On Windows, use the CLI.
- **Internet works but local devices don't:** turn on "Allow local network access" for that device.
- **`mullvad.net/check` complains about DNS leaks:** that's the trade-off of allowing local network access; it lets local DNS names keep working. Turn it off, or override DNS with a global nameserver in the admin console's DNS settings, if a clean leak test matters more to you.

## 4. Part 2: your own cloud server as an exit node

This is the same idea with a machine you rent. It costs about the same as the Mullvad add-on, gives you an IP nobody else uses, and puts the exit wherever your provider has a data centre.

### 4.1 Choosing a box

- **DigitalOcean** (what this project's automation targets): the $4/month droplet (512 MB RAM, 500 GB of transfer) works, but the $6/month one (1 GB RAM, 1 TB of transfer) is the better fit for something whose whole job is pushing traffic. Billing is per second, so experiments cost cents. The image to use is `ubuntu-24-04-x64`.
- **IPv6 is off by default** on DigitalOcean. Turn it on when you create the droplet (`--enable-ipv6` in their CLI, `ipv6: true` in the API), or IPv6 through the exit node won't work.
- There is no Tailscale one-click image on DigitalOcean's marketplace; you set it up yourself, which is a handful of commands.
- Other providers work the same way. Hetzner includes far more transfer per month; AWS charges per gigabyte of outbound traffic, which adds up fast for a VPN. Tailscale notes a known issue with Linux VM exit nodes on Google Cloud.
- Ubuntu 24.04 LTS is still a good choice and is what the commands below assume. (26.04 LTS exists now; 24.04 remains supported.)

### 4.2 Setting it up by hand (Ubuntu 24.04)

The automated version of all of this lives in [`automation/`](automation/README.md). This is what it does, one step at a time, so you understand it.

**a. Install Tailscale**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

**b. Let the server forward traffic**

A Linux box drops packets that aren't addressed to it. An exit node is a router, so we switch forwarding on for both IPv4 and IPv6:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

**Correction:** the original headed this step "Edit the sysctl.conf file". The commands (which were right) don't touch `/etc/sysctl.conf`; they create a drop-in file in `/etc/sysctl.d/`. Only on a system without that directory would you use `/etc/sysctl.conf` instead, with the same two lines and `sudo sysctl -p /etc/sysctl.conf`.

**c. Join the tailnet and offer to be an exit node**

```bash
sudo tailscale up --advertise-exit-node --ssh
```

Log in via the link it prints (or pass `--auth-key=` for an unattended setup, see 4.8). `--ssh` turns on Tailscale SSH so you can reach the box over the tailnet without managing SSH keys.

**Heads-up, the one that catches everyone:** `tailscale up` does not remember flags between runs. If you later run a plain `sudo tailscale up` for any reason, the server quietly stops being an exit node. Newer versions warn you and print the full command to copy, and `--reset` exists to deliberately clear settings. The habit to build: run `up` once with everything you want, and make later changes with `tailscale set`, which only touches the setting you name:

```bash
sudo tailscale set --advertise-exit-node   # turn it on later, without disturbing anything else
sudo tailscale set --auto-update           # let Tailscale keep itself current
```

**d. Firewall**

Leave your firewall's default alone. `ufw` and `firewalld` both refuse to forward traffic by default, and that's what Tailscale wants; it adds its own rules for the tunnel. Do **not** add `ufw route allow` rules or flip the forward policy to accept. The one exception is `firewalld`, which needs masquerading turned on because of a known issue:

```bash
sudo firewall-cmd --permanent --add-masquerade
```

**e. Performance tweak Tailscale recommends for exit nodes**

Let the network card batch UDP packets. Needs Tailscale 1.54 or newer and a Linux 6.2 or newer kernel (Ubuntu 24.04 ships 6.8):

```bash
NETDEV=$(ip -o route get 8.8.8.8 | cut -f 5 -d " ")
sudo ethtool -K $NETDEV rx-udp-gro-forwarding on rx-gro-list off
```

That setting is lost on reboot, so make it stick with a small script that runs whenever the network comes up:

```bash
printf '#!/bin/sh\n\nethtool -K %s rx-udp-gro-forwarding on rx-gro-list off \n' "$(ip -o route get 8.8.8.8 | cut -f 5 -d " ")" | sudo tee /etc/networkd-dispatcher/routable.d/50-tailscale
sudo chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale
```

### 4.3 Approving the node

Offering to be an exit node isn't enough; an admin has to accept the offer. Two ways.

**By hand. Do this:**

1. Admin console → **Machines**. Filtering with `property:exit-node` finds nodes that are offering.
2. Open the node's menu → **Edit route settings**.
3. Tick the **Use as exit node** checkbox and select **Save**.

**Correction:** the original called it a toggle under an "Exit node" heading and left out **Save**. It's a checkbox, and nothing happens until you save.

**Automatically, with the policy file.** Tag the server and tell Tailscale that anything with that tag is pre-approved:

```jsonc
"tagOwners":     {"tag:exit": ["autogroup:admin"]},
"autoApprovers": {"exitNode": ["tag:exit"]},
```

Then join with `--advertise-tags=tag:exit` (or an auth key that carries the tag). **Heads-up:** the policy must be saved *before* the node registers; a node that joined earlier still needs the manual approval once.

### 4.4 Key expiry

Every device on a tailnet has to re-authenticate every 180 days by default, and a headless server won't. When its key expires it just drops off, usually months after you've forgotten how it was set up.

Tagging the server (4.3) fixes this: tagged devices have key expiry disabled from the start. If you'd rather not tag it, open the node's menu on the Machines page and choose **Disable key expiry**.

### 4.5 Using it from your devices

The original document ended once the server existed. Here's the half it left out.

- **macOS:** Tailscale menu → **Exit Nodes**, pick the server. **Allow Local Network Access** is in the same menu.
- **Windows:** Tailscale icon → **Exit Nodes** → your server. **Allow local network access** is there too.
- **iOS:** the exit-node control sits at the top of the app. **None** turns it off.
- **Android:** menu → **Use exit node**, with an **Allow LAN access** toggle.
- **Linux / CLI:**

  ```bash
  tailscale exit-node list                                     # what's on offer
  sudo tailscale set --exit-node=exit-nyc1 --exit-node-allow-lan-access=true
  sudo tailscale set --exit-node=                              # back to normal
  ```

  With MagicDNS on (it is by default) the short hostname works; otherwise use the node's Tailscale IP.

Each device chooses independently. Turning on an exit node on your laptop does nothing to your phone.

### 4.6 Verifying

On the server:

```bash
tailscale status                 # shows the tailnet and that you're connected
sysctl net.ipv4.ip_forward       # expect 1
```

From a client, after selecting the exit node:

```bash
curl -4 https://ifconfig.me      # expect the server's public IPv4
curl -6 https://ifconfig.me      # expect its IPv6, if you enabled it
```

If the server shows up in `tailscale status` but not in `tailscale exit-node list`, it hasn't been approved yet (4.3).

### 4.7 Streaming and CAPTCHAs

**Correction:** the original promised "very low risk" of blocks because the IP is dedicated. That's backwards. Streaming services and bot detectors block by network range, and cloud providers' ranges are exactly the ranges they block, because that's where scrapers and bots live. A dedicated IP means nobody else is dragging its reputation down, which helps a little; it doesn't make you look like a home connection. Expect the same "mixed" experience as with Mullvad, just for a different reason.

### 4.8 Automating it

The [`automation/`](automation/README.md) folder in this project turns 4.2 through 4.4 into one command against DigitalOcean, in two flavours: a cloud-init file plus a shell script, and a Terraform module. It is a proof of concept, validated offline only; it has not yet been run against a live DigitalOcean account. The ideas behind it, which apply to any provider:

- Put the policy rules (4.3) in place first.
- Use a **one-off, pre-approved, tagged** auth key with a short expiry, and never an ephemeral one (ephemeral nodes are deleted after an hour of silence, which is the opposite of what you want from a server).
- Hand the key to the server in a root-only file and delete it after `tailscale up`. Never on the command line.
- Run `tailscale up` exactly once, at first boot, with every flag. Everything after that is `tailscale set`.

## 5. Which one is for me?

**Pick Mullvad if** the point is choosing a country, you have five or fewer devices, and you never want to think about a server. You'll pay $5 a month and get a new location with two clicks.

**Pick your own server if** you want an IP address that is yours and doesn't change (some services, and your own allow-lists, care about that), you'd like to choose the exact data centre, or you have more devices than a Mullvad licence pack covers. You'll pay about the same and spend roughly fifteen minutes on setup by hand. The automation should cut that to a few minutes once it has been tested live.

**Do both** if the two jobs are different: Mullvad for casual browsing from wherever, the VPS for a stable address you can rely on. Exit nodes are picked per device and per moment, so nothing stops you switching between them.

**Do neither** if what you actually need is anonymity from Tailscale itself. Neither option gives you that; Tailscale knows who you are either way. Buy Mullvad directly, or use Tor.

## 6. Corrections log

| # | Where | The original said | What's actually true | Source | Type |
|---|---|---|---|---|---|
| 1 | Mullvad, buying | Click **Manage** in the Mullvad VPN section | The button is **Configure**; "Manage add-ons" is on the Billing page | [Mullvad exit nodes](https://tailscale.com/docs/features/exit-nodes/mullvad-exit-nodes) | wrong |
| 2 | Mullvad, setup | "Very Low (1 click)" | Checkout, then authorise each device, then each device picks a node | same | wrong |
| 3 | Mullvad, anonymity | "High (shared IP with thousands)" | Tailscale is identity-aware, holds the Mullvad accounts, and can log which device used which server | same, "Data privacy and anonymity" | misleading |
| 4 | Mullvad, architecture | Mullvad servers sit on an isolated tailnet peered with yours | Your device's existing key is registered with Mullvad and the servers are added to your network map; direct WireGuard to the server | [Launch post](https://tailscale.com/blog/mullvad-integration) | wrong |
| 5 | Mullvad, locations | "40+ countries" | Tailscale gives no number; Mullvad lists 50 countries, 91 cities today | [Mullvad servers](https://mullvad.net/en/servers) | outdated |
| 6 | Mullvad, status | (nothing) | The feature is still labelled beta | Mullvad exit nodes docs | missing |
| 7 | Mullvad, limits | (nothing) | Windows can't list all nodes; incompatible with custom DERP and Google-synced groups; Tailnet Lock needs signing; two-minute first sync | same | missing |
| 8 | Both, streaming | Mullvad "high risk", VPS "very low risk (dedicated IP)" | Tailscale's docs say nothing about streaming; both are "mixed", and data-centre ranges are commonly blocked | general knowledge, flagged as such | wrong |
| 9 | VPS, step 2 | "Edit the sysctl.conf file" | The commands write `/etc/sysctl.d/99-tailscale.conf`; `/etc/sysctl.conf` is only the fallback | [Subnet routers](https://tailscale.com/kb/1019/subnets) | wrong |
| 10 | VPS, methodology | "The daemon announces itself as an exit node" | Nothing happens until you run `tailscale up`/`set` with `--advertise-exit-node` | [Exit node setup](https://tailscale.com/docs/features/exit-nodes/how-to/setup) | misleading |
| 11 | VPS, step 4 | `sudo tailscale up --advertise-exit-node` with no caveat | Works, but `up` forgets flags between runs; use `tailscale set` for later changes | [tailscale up](https://tailscale.com/kb/1241/tailscale-up) | missing |
| 12 | VPS, step 5 | Toggle "Use as exit node" under an "Exit node" heading | It's a checkbox, and you must select **Save** | Exit node setup docs | imprecise |
| 13 | VPS, approval | "The admin must explicitly approve" | Or the policy's `autoApprovers.exitNode` approves tagged nodes automatically | [Policy syntax](https://tailscale.com/kb/1337/acl-syntax) | missing |
| 14 | VPS, firewall | (nothing) | Keep the default deny-forwarding; only firewalld needs masquerade | Subnet routers docs | missing |
| 15 | VPS, performance | (nothing) | UDP GRO forwarding tweak, persisted with a dispatcher script | [Performance](https://tailscale.com/kb/1320/performance-best-practices) | missing |
| 16 | VPS, longevity | (nothing) | Node keys expire after 180 days unless the node is tagged or expiry is disabled | [Key expiry](https://tailscale.com/kb/1028/key-expiry) | missing |
| 17 | VPS, using it | (nothing) | How to select the exit node on each platform, LAN access, `exit-node list` / `suggest` | Exit node docs | missing |
| 18 | VPS, cloud notes | (nothing) | DigitalOcean IPv6 is off by default; no Tailscale one-click image; known GCP issue | [Exit nodes](https://tailscale.com/docs/features/exit-nodes) | missing |
| 19 | Both, console URL | `login.tailscale.com` | Now `console.tailscale.com` (the old address redirects) | admin console | outdated |

## 7. Sources

All checked on 8 September 2026.

- Tailscale: [Exit nodes](https://tailscale.com/docs/features/exit-nodes) · [Set up an exit node](https://tailscale.com/docs/features/exit-nodes/how-to/setup) · [Mullvad exit nodes](https://tailscale.com/docs/features/exit-nodes/mullvad-exit-nodes) · [Mullvad integration announcement](https://tailscale.com/blog/mullvad-integration) · [Pricing](https://tailscale.com/pricing)
- Tailscale: [Subnet routers (IP forwarding and firewall notes)](https://tailscale.com/kb/1019/subnets) · [Performance best practices](https://tailscale.com/kb/1320/performance-best-practices) · [tailscale up](https://tailscale.com/kb/1241/tailscale-up) · [CLI reference](https://tailscale.com/kb/1080/cli) · [Key expiry](https://tailscale.com/kb/1028/key-expiry) · [Auth keys](https://tailscale.com/kb/1085/auth-keys) · [Ephemeral nodes](https://tailscale.com/kb/1111/ephemeral-nodes) · [Tags](https://tailscale.com/kb/1068/acl-tags) · [Policy file syntax](https://tailscale.com/kb/1337/acl-syntax) · [Install with cloud-init](https://tailscale.com/kb/1293/cloud-init) · [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) · [Install on Linux](https://tailscale.com/kb/1031/install-linux)
- Mullvad: [Server list](https://mullvad.net/en/servers)
- DigitalOcean: [Droplet pricing](https://www.digitalocean.com/pricing/droplets) · [API tokens and scopes](https://docs.digitalocean.com/reference/api/create-personal-access-token/) · [Provide user data](https://docs.digitalocean.com/products/droplets/how-to/provide-user-data/)
