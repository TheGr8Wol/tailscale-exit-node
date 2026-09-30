output "droplet_id" {
  description = "DigitalOcean droplet id."
  value       = digitalocean_droplet.exit.id
}

output "droplet_ipv4" {
  description = "Public IPv4 of the droplet; this is what websites will see."
  value       = digitalocean_droplet.exit.ipv4_address
}

output "droplet_ipv6" {
  description = "Public IPv6 of the droplet."
  value       = digitalocean_droplet.exit.ipv6_address
}

output "node_hostname" {
  description = "Short tailnet hostname. With MagicDNS on, this is all you need in --exit-node=."
  value       = var.name
}

output "node_fqdn" {
  description = "Full tailnet name, when wait_for_device is true."
  value       = try(data.tailscale_device.exit[0].name, "set wait_for_device = true to resolve the tailnet name")
}

output "tailnet_key_id" {
  description = "Id of the auth key, handy for revoking it in Settings -> Keys. Not the key itself."
  value       = tailscale_tailnet_key.exit.id
}

output "next_steps" {
  description = "What to run on a device once the node is up."
  value       = <<-EOT
    Check it appeared:        tailscale exit-node list
    Route through it:         tailscale set --exit-node=${var.name} --exit-node-allow-lan-access=true
    Confirm the public IP:    curl -4 https://ifconfig.me   (expect ${digitalocean_droplet.exit.ipv4_address})
    Stop routing through it:  tailscale set --exit-node=
  EOT
}
