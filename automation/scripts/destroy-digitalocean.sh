#!/usr/bin/env bash
# destroy-digitalocean.sh
#
# Tears down an exit node made by provision-digitalocean.sh: deletes the
# droplet and, if you ask, removes the machine from your tailnet too. Deleting
# the droplet alone leaves a dead entry on the Machines page, which is
# harmless but untidy.
#
# If this Mac is currently routing through the node, the script switches the
# exit node off first so you are not left without internet.
#
# Run with --help for the options.

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

NAME=""
DO_TAG=""
REMOVE_DEVICE=0
DEVICE_ONLY=0
DEVICE_ID=""
DRY_RUN=0
ASSUME_YES=0
STATE_DIR="$SCRIPT_DIR/.state"

usage() {
  cat <<'USAGE'
Usage: destroy-digitalocean.sh (--name NAME | --tag TAG) [options]

Deletes the droplet(s) and optionally the matching machine(s) on your tailnet.

Secrets come from the environment:
  DIGITALOCEAN_TOKEN     DigitalOcean API token (droplet read/delete).
  For --remove-device, one of:
    TS_API_KEY                                   an API access token, or
    TS_OAUTH_CLIENT_ID + TS_OAUTH_CLIENT_SECRET  an OAuth client with the
                                                 devices:core scope bound to tag:exit

Options:
  --name NAME        Delete the droplet with this exact name.
  --tag TAG          Delete EVERY droplet carrying this DigitalOcean tag. Needs --yes.
  --remove-device    Also remove the machine from the tailnet through the Tailscale API.
  --device-only      Skip DigitalOcean entirely; only remove the tailnet machine.
  --device-id ID     Tailnet device id to remove, if the name matches more than one.
  --dry-run          Show what would be deleted and stop.
  --yes              Do not ask for confirmation.
  --state-dir DIR    Where provision-digitalocean.sh recorded droplets (default scripts/.state).
  -h, --help         This text.

Examples:
  ./destroy-digitalocean.sh --name exit-nyc1
  ./destroy-digitalocean.sh --name exit-nyc1 --remove-device
  ./destroy-digitalocean.sh --tag tailscale-exit --yes
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)          need_arg "$@"; NAME="$2"; shift 2 ;;
    --tag)           need_arg "$@"; DO_TAG="$2"; shift 2 ;;
    --remove-device) REMOVE_DEVICE=1; shift ;;
    --device-only)   DEVICE_ONLY=1; REMOVE_DEVICE=1; shift ;;
    --device-id)     need_arg "$@"; DEVICE_ID="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --yes)           ASSUME_YES=1; shift ;;
    --state-dir)     need_arg "$@"; STATE_DIR="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" 2 ;;
  esac
done

if [ -z "$NAME" ] && [ -z "$DO_TAG" ]; then
  die "give --name NAME or --tag TAG (try --help)" 2
fi
if [ -n "$DO_TAG" ] && [ -z "$NAME" ] && [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
  die "--tag deletes every droplet with that tag; add --yes to confirm you mean it" 2
fi
if [ "$DEVICE_ONLY" = 1 ] && [ -z "$NAME" ]; then
  die "--device-only needs --name" 2
fi
require_cmd curl python3

make_scratch
trap 'cleanup_scratch' EXIT
trap 'warn "failed during: $CURRENT_STEP"' ERR

TS_BIN="$(find_tailscale || true)"

# stop_using_exit_node NAME: if this machine routes through NAME, switch it off.
stop_using_exit_node() {
  local using
  [ -n "$TS_BIN" ] || return 0
  tailscale_running "$TS_BIN" || return 0
  using="$("$TS_BIN" status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
name = sys.argv[1]
for p in (d.get("Peer") or {}).values():
    if p.get("ExitNode") and (p.get("HostName") == name or (p.get("DNSName") or "").startswith(name + ".")):
        print("yes"); sys.exit()
print("no")' "$1" 2>/dev/null || echo no)"
  if [ "$using" = "yes" ]; then
    log "this machine is routing through $1; switching the exit node off first"
    if [ "$DRY_RUN" != 1 ]; then
      "$TS_BIN" set --exit-node= || warn "could not switch the exit node off; do it from the Tailscale menu"
    fi
  fi
}

DROPLET_NAMES=""

# ---------------------------------------------------------------------------
# DigitalOcean
# ---------------------------------------------------------------------------
if [ "$DEVICE_ONLY" != 1 ]; then
  step "finding droplets on DigitalOcean"
  require_env DIGITALOCEAN_TOKEN
  if [ -n "$NAME" ]; then
    query="/droplets?per_page=200&name=$NAME"
  else
    query="/droplets?per_page=200&tag_name=$DO_TAG"
  fi
  code="$(do_api GET "$query" "$TMP/droplets.json")" \
    || die "could not list droplets (HTTP $code): $(api_error_message "$TMP/droplets.json")"
  # One droplet per line: id<TAB>name<TAB>ipv4<TAB>created_at
  python3 - "$TMP/droplets.json" "$NAME" > "$TMP/targets.tsv" <<'PY'
import json, sys
droplets = json.load(open(sys.argv[1])).get("droplets", [])
name = sys.argv[2]
for d in droplets:
    if name and d["name"].lower() != name.lower():
        continue
    v4 = [n["ip_address"] for n in (d.get("networks") or {}).get("v4", []) if n.get("type") == "public"]
    print("%s\t%s\t%s\t%s" % (d["id"], d["name"], v4[0] if v4 else "-", d.get("created_at", "")))
PY
  if [ ! -s "$TMP/targets.tsv" ]; then
    log "no matching droplets on DigitalOcean"
  else
    log "matching droplets:"
    while IFS="$(printf '\t')" read -r id name ip created; do
      log "  id $id  $name  $ip  created $created"
      DROPLET_NAMES="${DROPLET_NAMES}${name}
"
    done < "$TMP/targets.tsv"
    if [ "$DRY_RUN" = 1 ]; then
      log "dry run: these would be deleted"
    else
      confirm "Delete these droplet(s)? This cannot be undone." || die "cancelled" 0
      while IFS="$(printf '\t')" read -r id name ip created; do
        stop_using_exit_node "$name"
        step "deleting droplet $name (id $id)"
        code="$(do_api DELETE "/droplets/$id" "$TMP/delete.json")" \
          || die "DigitalOcean refused the delete (HTTP $code): $(api_error_message "$TMP/delete.json")"
        rm -f "$STATE_DIR/$name.json"
        log "deleted"
      done < "$TMP/targets.tsv"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Tailnet machine
# ---------------------------------------------------------------------------
if [ "$REMOVE_DEVICE" != 1 ]; then
  if [ -n "$DROPLET_NAMES" ] || [ -n "$NAME" ]; then
    log "the machine entry stays on your tailnet; remove it in the admin console (Machines -> the node -> Remove) or rerun with --remove-device"
  fi
  exit 0
fi

step "removing the machine from the tailnet"
if [ -n "$NAME" ]; then
  wanted="$NAME"
else
  wanted="$DROPLET_NAMES"
fi
[ -n "$wanted" ] || { log "nothing to remove from the tailnet"; exit 0; }
ts_get_access_token
code="$(ts_api GET "/tailnet/-/devices" "$TMP/devices.json")" \
  || die "could not list tailnet devices (HTTP $code): $(api_error_message "$TMP/devices.json")"
printf '%s\n' "$wanted" | while read -r name; do
  [ -n "$name" ] || continue
  matches="$(DEVICE_ID="$DEVICE_ID" python3 - "$TMP/devices.json" "$name" <<'PY'
import json, os, sys
devices = json.load(open(sys.argv[1])).get("devices", [])
name = sys.argv[2]
forced = os.environ.get("DEVICE_ID", "")
hits = []
for d in devices:
    did = str(d.get("id", ""))
    if forced and did == forced:
        hits = [d]; break
    if d.get("hostname") == name or (d.get("name") or "").startswith(name + "."):
        hits.append(d)
for d in hits:
    print("%s\t%s\t%s" % (d.get("id"), d.get("name"), ",".join(d.get("tags") or [])))
PY
)"
  if [ -z "$matches" ]; then
    warn "no tailnet machine called $name; nothing to remove"
    continue
  fi
  count="$(printf '%s\n' "$matches" | grep -c .)"
  if [ "$count" -gt 1 ]; then
    warn "more than one machine matches $name:"
    printf '%s\n' "$matches" | while IFS="$(printf '\t')" read -r id fqdn tags; do warn "  id $id  $fqdn  $tags"; done
    die "rerun with --device-id ID to pick one" 2
  fi
  id="${matches%%	*}"
  fqdn="$(printf '%s' "$matches" | cut -f2)"
  if [ "$DRY_RUN" = 1 ]; then
    log "dry run: would remove $fqdn (id $id) from the tailnet"
    continue
  fi
  stop_using_exit_node "$name"
  code="$(ts_api DELETE "/device/$id" "$TMP/device-delete.json")" \
    || die "Tailscale refused the delete (HTTP $code): $(api_error_message "$TMP/device-delete.json")"
  log "removed $fqdn from the tailnet"
done
