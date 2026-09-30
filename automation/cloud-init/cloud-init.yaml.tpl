#cloud-config
# Tailscale exit node: first-boot configuration for Ubuntu 24.04 on DigitalOcean.
#
# This file is a template. Three placeholders, written as a dollar sign, a brace,
# the name and a closing brace, are filled in before it is sent to the server,
# either by provision-digitalocean.sh or by Terraform's templatefile():
#   hostname      the name the machine will have on your tailnet
#   ts_tag        the tag that makes it self-approving (normally tag:exit)
#   authkey_b64   a one-off Tailscale auth key, base64-encoded so that no
#                   character in it can ever break this YAML
# Everything else with a dollar sign ($NETDEV, $(...), $UPTIME) is ordinary shell
# and both renderers leave it alone.
#
# What happens on first boot, in order (cloud-init writes files before it runs
# commands, so the ordering below is guaranteed):
#   1. Three files land on disk: the kernel forwarding settings, a small script
#      that turns on a network-card optimisation Tailscale recommends for exit
#      nodes, and the auth key in a root-only file.
#   2. Forwarding is switched on, Tailscale is installed, the optimisation runs.
#   3. Tailscale joins your tailnet ONCE with every flag it needs. Later changes
#      go through `tailscale set`, because re-running `tailscale up` silently
#      drops any flag you forget to repeat.
#   4. The auth key file is shredded. It was single-use anyway.

package_update: true
package_upgrade: false
packages:
  - ethtool
  - networkd-dispatcher

# Nobody should be logging in with a password. If DigitalOcean emailed you a root
# password because no SSH key was attached, it still works in the web Recovery
# Console, just not over SSH. Tailscale SSH covers everyday access.
ssh_pwauth: false

write_files:
  # Let the kernel forward packets that aren't addressed to this machine.
  # Without this the server can't act as a router, and an exit node is a router.
  - path: /etc/sysctl.d/99-tailscale.conf
    permissions: '0644'
    content: |
      net.ipv4.ip_forward = 1
      net.ipv6.conf.all.forwarding = 1

  # Tailscale's performance tip for exit nodes: let the network card batch UDP
  # packets. The setting doesn't survive a reboot on its own, so this script runs
  # every time the network comes up. The interface name is looked up at run time
  # because we can't know it when the template is rendered.
  - path: /etc/networkd-dispatcher/routable.d/50-tailscale
    permissions: '0755'
    content: |
      #!/bin/sh
      NETDEV="$(ip -o route get 8.8.8.8 | cut -f 5 -d ' ')"
      if [ -n "$NETDEV" ]; then
        ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
      fi
      exit 0

  # The auth key, readable by root only and deleted a few seconds later. Passing
  # it through a file (rather than on the command line) keeps it out of the
  # process list and out of cloud-init's command log.
  - path: /run/tailscale-authkey
    permissions: '0600'
    owner: root:root
    encoding: b64
    content: "${authkey_b64}"

runcmd:
  - sysctl --system
  - [sh, -c, 'curl -fsSL https://tailscale.com/install.sh | sh']
  - [sh, -c, '/etc/networkd-dispatcher/routable.d/50-tailscale || true']
  - tailscale up --auth-key=file:/run/tailscale-authkey --advertise-tags=${ts_tag} --advertise-exit-node --ssh --hostname=${hostname} --accept-dns=false
  - tailscale set --auto-update
  - [sh, -c, 'shred -u /run/tailscale-authkey 2>/dev/null || rm -f /run/tailscale-authkey']

final_message: "tailscale exit node ${hostname} is bootstrapped after $UPTIME seconds"
