#!/usr/bin/env bash
# provision-digitalocean.sh
#
# Creates a DigitalOcean droplet that installs Tailscale on first boot, joins
# your tailnet under a tag, and offers itself as an exit node. Nothing to
# install: curl and python3 are all it needs, and both ship with macOS.
#
# Run with --help for the options. RUNBOOK.md in the project root walks through
# the whole thing, including the policy-file edit that has to happen first
# (without it the node joins but never gets approved as an exit node).
#
# Exit codes: 0 done, 1 something failed, 2 bad arguments, 3 the droplet is up
# but did not show up as an exit node within the verify timeout.

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults; every one has a flag
# ---------------------------------------------------------------------------
NAME=""
REGION="nyc1"
SIZE="s-1vcpu-1gb"
IMAGE="ubuntu-24-04-x64"
DO_TAG="tailscale-exit"
TS_TAG="tag:exit"
KEY_EXPIRY=900
VERIFY_TIMEOUT=300
NO_VERIFY=0
DRY_RUN=0
OFFLINE=0
NO_SSH_KEYS=0
SSH_KEY_WANTED=""          # newline-separated ids, names or fingerprints
TEMPLATE="$SCRIPT_DIR/../cloud-init/cloud-init.yaml.tpl"
STATE_DIR="$SCRIPT_DIR/.state"
RENDER_OUT=""
DROPLET_ID=""
KEY_ID=""
SSH_KEY_IDS=""
IPV4=""
IPV6=""

usage() {
  cat <<'USAGE'
Usage: provision-digitalocean.sh [options]

Creates a DigitalOcean droplet that installs Tailscale on first boot, joins your
tailnet under a tag, and advertises itself as an exit node.

Secrets come from the environment, never from flags:
  DIGITALOCEAN_TOKEN     DigitalOcean API token. Custom scopes are enough:
                         droplet create/read/delete, ssh_key read, region read.
  TS_AUTHKEY             A Tailscale auth key made in the admin console (Settings
                         -> Keys): one-off, pre-approved, tagged tag:exit, NOT
                         ephemeral, expiry as short as the console allows.
    -- or --
  TS_OAUTH_CLIENT_ID and TS_OAUTH_CLIENT_SECRET
                         An OAuth client with the auth_keys scope bound to
                         tag:exit. The script mints a 15-minute one-off key.

Options:
  --name NAME            Droplet name and tailnet hostname (default ts-exit-<region>).
                         Lowercase letters, digits and dashes only.
  --region SLUG          DigitalOcean region (default nyc1).
  --size SLUG            Droplet size (default s-1vcpu-1gb: about $6/month, 1 TB
                         of transfer, which suits an exit node better than the
                         $4 tier's 500 GB).
  --image SLUG           Image (default ubuntu-24-04-x64).
  --tag TAG              DigitalOcean tag put on the droplet (default tailscale-exit).
  --ts-tag TAG           Tailscale tag the node joins with (default tag:exit).
  --ssh-key ID|NAME|FP   Attach this DigitalOcean SSH key; repeatable. Default is
                         every key on the account.
  --no-ssh-keys          Attach none. DigitalOcean then emails a root password,
                         which only works in their web console (password SSH
                         is disabled by cloud-init).
  --key-expiry SECONDS   Lifetime of a minted auth key (default 900).
  --template FILE        cloud-init template (default ../cloud-init/cloud-init.yaml.tpl).
  --verify-timeout SEC   How long to wait for the node to appear as an exit node
                         on this machine's tailnet (default 300).
  --no-verify            Skip that local check.
  --dry-run              Show the request that would be sent, then stop. No
                         droplet is created and no key is minted.
  --offline              Like --dry-run but with no API calls at all.
  --render-out FILE      With --dry-run/--offline: also save the rendered
                         cloud-init file for inspection.
  --state-dir DIR        Where to record created droplets (default scripts/.state).
  -h, --help             This text.

Examples:
  ./provision-digitalocean.sh --name exit-nyc1 --region nyc1 --dry-run
  ./provision-digitalocean.sh --name exit-nyc1 --region nyc1
USAGE
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --name)           need_arg "$@"; NAME="$2"; shift 2 ;;
    --region)         need_arg "$@"; REGION="$2"; shift 2 ;;
    --size)           need_arg "$@"; SIZE="$2"; shift 2 ;;
    --image)          need_arg "$@"; IMAGE="$2"; shift 2 ;;
    --tag)            need_arg "$@"; DO_TAG="$2"; shift 2 ;;
    --ts-tag)         need_arg "$@"; TS_TAG="$2"; shift 2 ;;
    --ssh-key)        need_arg "$@"; SSH_KEY_WANTED="${SSH_KEY_WANTED}${2}
"; shift 2 ;;
    --no-ssh-keys)    NO_SSH_KEYS=1; shift ;;
    --key-expiry)     need_arg "$@"; KEY_EXPIRY="$2"; shift 2 ;;
    --template)       need_arg "$@"; TEMPLATE="$2"; shift 2 ;;
    --verify-timeout) need_arg "$@"; VERIFY_TIMEOUT="$2"; shift 2 ;;
    --no-verify)      NO_VERIFY=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --offline)        OFFLINE=1; DRY_RUN=1; shift ;;
    --render-out)     need_arg "$@"; RENDER_OUT="$2"; shift 2 ;;
    --state-dir)      need_arg "$@"; STATE_DIR="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (try --help)" 2 ;;
  esac
done

[ -n "$NAME" ] || NAME="ts-exit-$REGION"
printf '%s' "$NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$' \
  || die "--name must be lowercase letters, digits and dashes (got: $NAME)" 2
case "$TS_TAG" in tag:?*) ;; *) die "--ts-tag must look like tag:something (got: $TS_TAG)" 2 ;; esac
case "$KEY_EXPIRY" in ''|*[!0-9]*) die "--key-expiry must be a number of seconds" 2 ;; esac
case "$VERIFY_TIMEOUT" in ''|*[!0-9]*) die "--verify-timeout must be a number of seconds" 2 ;; esac
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE" 2
if [ -n "$RENDER_OUT" ] && [ "$DRY_RUN" != 1 ]; then
  die "--render-out only works together with --dry-run or --offline" 2
fi
require_cmd curl python3

# ---------------------------------------------------------------------------
# Scratch space and traps
# ---------------------------------------------------------------------------
make_scratch
trap 'cleanup_scratch' EXIT
# shellcheck disable=SC2329  # invoked through the ERR trap
on_error() {
  local rc=$?
  warn "failed during: $CURRENT_STEP (exit $rc)"
  if [ -n "$DROPLET_ID" ]; then
    warn "a droplet was created (id $DROPLET_ID, name $NAME). Remove it with:"
    warn "  $SCRIPT_DIR/destroy-digitalocean.sh --name $NAME"
  fi
}
trap 'on_error' ERR

manual_checks() {
  cat >&2 <<TXT

How to check the node by hand:
  - Admin console -> Machines, filter "property:exit-node": $NAME should be listed with $TS_TAG.
  - From any device on the tailnet:  tailscale exit-node list
  - If the droplet is visible but is not an exit node, either the policy file was
    saved after the node registered (approve it once by hand: Machines -> $NAME ->
    Edit route settings -> Use as exit node -> Save) or the tag is missing.
  - First-boot log on the droplet:   ssh root@${IPV4:-<droplet-ip>} 'cloud-init status --wait; tail -50 /var/log/cloud-init-output.log'
TXT
}

success_message() {
  local v4="${IPV4:-the droplet IPv4}" v6="${IPV6:-the droplet IPv6}"
  cat >&2 <<TXT

$NAME is ready. To route this machine's internet traffic through it:
  tailscale set --exit-node=$NAME --exit-node-allow-lan-access=true
  curl -4 https://ifconfig.me        # should print $v4
  curl -6 https://ifconfig.me        # should print $v6
And to stop:
  tailscale set --exit-node=
TXT
}

# ---------------------------------------------------------------------------
# Preflight against DigitalOcean (skipped in --offline mode)
# ---------------------------------------------------------------------------
if [ "$OFFLINE" = 1 ]; then
  log "offline mode: skipping every API call"
else
  step "checking the DigitalOcean region, size and existing droplets"
  require_env DIGITALOCEAN_TOKEN
  code="$(do_api GET "/regions?per_page=200" "$TMP/regions.json")" \
    || die "could not list regions (HTTP $code): $(api_error_message "$TMP/regions.json")"
  python3 - "$TMP/regions.json" "$REGION" "$SIZE" <<'PY' || die "preflight failed"
import json, sys
regions = json.load(open(sys.argv[1]))["regions"]
region, size = sys.argv[2], sys.argv[3]
match = [r for r in regions if r["slug"] == region]
if not match:
    avail = ", ".join(sorted(r["slug"] for r in regions if r.get("available")))
    sys.exit("unknown region %r. Available: %s" % (region, avail))
r = match[0]
if not r.get("available"):
    sys.exit("region %s is not accepting new droplets right now" % region)
if size not in r.get("sizes", []):
    sys.exit("size %s is not offered in %s. Offered there: %s" % (size, region, ", ".join(sorted(r["sizes"]))))
print("region %s and size %s look fine" % (region, size))
PY

  code="$(do_api GET "/droplets?per_page=200&name=$NAME" "$TMP/droplets.json")" \
    || die "could not list droplets (HTTP $code): $(api_error_message "$TMP/droplets.json")"
  python3 - "$TMP/droplets.json" "$NAME" <<'PY' || die "preflight failed"
import json, sys
droplets = json.load(open(sys.argv[1])).get("droplets", [])
dup = [d for d in droplets if d["name"].lower() == sys.argv[2].lower()]
if dup:
    sys.exit("a droplet named %s already exists (id %s). Pick another --name or destroy it first."
             % (sys.argv[2], dup[0]["id"]))
PY

  if [ "$NO_SSH_KEYS" = 1 ]; then
    warn "no SSH key will be attached; DigitalOcean will email a root password (usable in their web console only)"
  else
    code="$(do_api GET "/account/keys?per_page=200" "$TMP/keys.json")" \
      || die "could not list SSH keys (HTTP $code): $(api_error_message "$TMP/keys.json")"
    SSH_KEY_IDS="$(SSH_KEY_WANTED="$SSH_KEY_WANTED" python3 - "$TMP/keys.json" <<'PY'
import json, os, sys
keys = json.load(open(sys.argv[1])).get("ssh_keys", [])
wanted = [w.strip() for w in os.environ.get("SSH_KEY_WANTED", "").splitlines() if w.strip()]
if not wanted:
    print(" ".join(str(k["id"]) for k in keys))
    sys.exit()
ids = []
for w in wanted:
    hit = [k for k in keys if str(k["id"]) == w or k["name"] == w or k["fingerprint"] == w]
    if not hit:
        have = ", ".join(k["name"] for k in keys) or "none"
        sys.exit("SSH key %r is not on the account (have: %s)" % (w, have))
    ids.append(str(hit[0]["id"]))
print(" ".join(ids))
PY
)" || die "could not resolve SSH keys"
    if [ -z "$SSH_KEY_IDS" ]; then
      warn "the account has no SSH keys, so DigitalOcean will email a root password (usable in their web console only)"
    else
      log "attaching SSH key id(s): $SSH_KEY_IDS"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# The auth key
# ---------------------------------------------------------------------------
step "getting a Tailscale auth key"
AUTHKEY=""
if [ -n "${TS_AUTHKEY:-}" ]; then
  printf '%s' "$TS_AUTHKEY" | grep -Eq '^tskey-auth-[A-Za-z0-9_-]+$' \
    || die "TS_AUTHKEY does not look like a Tailscale auth key (they start with tskey-auth-)"
  AUTHKEY="$TS_AUTHKEY"
  log "using the auth key from TS_AUTHKEY"
elif [ "$DRY_RUN" = 1 ]; then
  AUTHKEY="tskey-auth-DRYRUN-not-a-real-key"
  log "dry run: using a placeholder key, nothing is minted"
else
  if [ -z "${TS_OAUTH_CLIENT_ID:-}" ] || [ -z "${TS_OAUTH_CLIENT_SECRET:-}" ]; then
    die "set TS_AUTHKEY, or TS_OAUTH_CLIENT_ID and TS_OAUTH_CLIENT_SECRET (see --help)"
  fi
  ts_get_access_token
  python3 - "$TMP/key-req.json" "$TS_TAG" "$KEY_EXPIRY" "$NAME" <<'PY'
import json, sys
body = {
    "capabilities": {"devices": {"create": {
        "reusable": False, "ephemeral": False, "preauthorized": True, "tags": [sys.argv[2]]}}},
    "expirySeconds": int(sys.argv[3]),
    "description": "exit node %s (provision-digitalocean.sh)" % sys.argv[4],
}
with open(sys.argv[1], "w") as f:
    json.dump(body, f)
PY
  code="$(ts_api POST "/tailnet/-/keys" "$TMP/key-resp.json" "$TMP/key-req.json")" \
    || die "minting the auth key failed (HTTP $code): $(api_error_message "$TMP/key-resp.json"). Does the OAuth client have the auth_keys scope and the tag $TS_TAG?"
  AUTHKEY="$(json_get key < "$TMP/key-resp.json")" || die "no key in the Tailscale response"
  KEY_ID="$(json_get id < "$TMP/key-resp.json" || true)"
  rm -f "$TMP/key-resp.json" "$TMP/key-req.json"
  log "minted a one-off auth key (id ${KEY_ID:-unknown}, valid for ${KEY_EXPIRY}s)"
fi

# ---------------------------------------------------------------------------
# Render the cloud-init file and the create request
# ---------------------------------------------------------------------------
step "rendering the cloud-init file"
# shellcheck disable=SC2016  # python source, single-quoted on purpose
PY_RENDER='
import base64, json, os, re, sys
key = sys.stdin.read().strip()
if not key:
    sys.exit("no auth key arrived on stdin")
values = {
    "hostname": os.environ["NAME"],
    "ts_tag": os.environ["TS_TAG"],
    "authkey_b64": base64.b64encode(key.encode()).decode(),
}
text = open(os.environ["TEMPLATE"], encoding="utf-8").read()
unknown = []
def sub(m):
    name = m.group(1)
    if name not in values:
        unknown.append(name)
        return m.group(0)
    return values[name]
rendered = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, text)
if unknown:
    sys.exit("the template uses placeholder(s) this script does not know: " + ", ".join(sorted(set(unknown))))
if not rendered.startswith("#cloud-config"):
    sys.exit("the rendered file does not start with #cloud-config")
if "${" in rendered:
    sys.exit("the rendered file still contains a ${ placeholder")
if len(rendered.encode()) > 65536:
    sys.exit("the rendered file is over DigitalOcean'"'"'s 64 KiB user-data limit")
ssh_ids = [int(x) for x in os.environ.get("SSH_KEY_IDS", "").split() if x]
body = {
    "name": os.environ["NAME"], "region": os.environ["REGION"], "size": os.environ["SIZE"],
    "image": os.environ["IMAGE"], "ipv6": True, "monitoring": True,
    "tags": [os.environ["DO_TAG"]], "ssh_keys": ssh_ids, "user_data": rendered,
}
def write(name, data):
    path = os.path.join(os.environ["OUT_DIR"], name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(data)
write("user-data.yaml", rendered)
write("create.json", json.dumps(body))
shown = dict(body)
shown["user_data"] = "<%d bytes, redacted>" % len(rendered.encode())
print(json.dumps(shown, indent=2))
'
printf '%s' "$AUTHKEY" \
  | NAME="$NAME" TS_TAG="$TS_TAG" REGION="$REGION" SIZE="$SIZE" IMAGE="$IMAGE" DO_TAG="$DO_TAG" \
    SSH_KEY_IDS="$SSH_KEY_IDS" TEMPLATE="$TEMPLATE" OUT_DIR="$TMP" python3 -c "$PY_RENDER" > "$TMP/summary.json" \
  || die "rendering failed"

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: this is what would be sent to POST $DO_API/droplets (user_data redacted)"
  cat "$TMP/summary.json"
  if [ -n "$RENDER_OUT" ]; then
    cp "$TMP/user-data.yaml" "$RENDER_OUT"
    log "rendered cloud-init saved to $RENDER_OUT (it embeds whatever key was used, so treat it accordingly)"
  fi
  log "nothing was created"
  exit 0
fi

# ---------------------------------------------------------------------------
# Create the droplet
# ---------------------------------------------------------------------------
step "creating droplet $NAME in $REGION ($SIZE, $IMAGE)"
code="$(do_api POST "/droplets" "$TMP/create-resp.json" "$TMP/create.json")" \
  || die "DigitalOcean refused the request (HTTP $code): $(api_error_message "$TMP/create-resp.json")"
DROPLET_ID="$(json_get droplet.id < "$TMP/create-resp.json")" || die "no droplet id in the response"
rm -f "$TMP/create.json" "$TMP/user-data.yaml"
mkdir -p "$STATE_DIR"
write_state "$STATE_DIR/$NAME.json" id "$DROPLET_ID" name "$NAME" region "$REGION" size "$SIZE" \
  image "$IMAGE" do_tag "$DO_TAG" ts_tag "$TS_TAG" authkey_id "$KEY_ID"
log "droplet created: id $DROPLET_ID (recorded in $STATE_DIR/$NAME.json)"

step "waiting for the droplet to become active"
deadline=$((SECONDS + 180))
while [ "$SECONDS" -lt "$deadline" ]; do
  if code="$(do_api GET "/droplets/$DROPLET_ID" "$TMP/droplet.json")"; then
    status="$(json_get droplet.status < "$TMP/droplet.json" || true)"
    if [ "$status" = "active" ]; then
      ips="$(droplet_public_ips "$TMP/droplet.json")"
      IPV4="${ips%% *}"; IPV6="${ips#* }"
      [ "$IPV4" = "-" ] && IPV4=""
      [ "$IPV6" = "-" ] && IPV6=""
      [ -n "$IPV4" ] && break
    fi
  else
    warn "status poll failed (HTTP $code); trying again"
  fi
  sleep 5
done
[ -n "$IPV4" ] || die "the droplet did not become active within 3 minutes; check the DigitalOcean console (id $DROPLET_ID)"
write_state "$STATE_DIR/$NAME.json" ipv4 "$IPV4" ipv6 "$IPV6"
log "droplet is active: IPv4 $IPV4, IPv6 ${IPV6:-none yet}"
log "cloud-init is now installing Tailscale on it; that usually takes one to two minutes"

# ---------------------------------------------------------------------------
# Verify from this machine's tailnet
# ---------------------------------------------------------------------------
if [ "$NO_VERIFY" = 1 ]; then
  manual_checks
  exit 0
fi
step "waiting for $NAME to show up as an exit node on this tailnet"
TS_BIN="$(find_tailscale || true)"
if [ -z "$TS_BIN" ] || ! tailscale_running "$TS_BIN"; then
  warn "no connected Tailscale client on this machine, so the last check is manual"
  manual_checks
  exit 0
fi
deadline=$((SECONDS + VERIFY_TIMEOUT))
joined=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if "$TS_BIN" exit-node list 2>/dev/null | grep -Eq "^[[:space:]]*[0-9a-fA-F.:]+[[:space:]]+${NAME}(\.|[[:space:]])"; then
    log "$NAME is available as an exit node"
    success_message
    exit 0
  fi
  if [ "$joined" = 0 ] && "$TS_BIN" status 2>/dev/null | grep -Eq "[[:space:]]${NAME}[[:space:]]"; then
    joined=1
    log "$NAME has joined the tailnet; waiting for it to be approved as an exit node"
  fi
  sleep 10
done
warn "$NAME did not appear as an exit node within ${VERIFY_TIMEOUT}s"
if [ "$joined" = 1 ]; then
  warn "it IS on the tailnet, so approval is the likely problem: the policy's autoApprovers rule was missing or saved too late, or the node did not get $TS_TAG"
else
  warn "it has not joined the tailnet yet; cloud-init may still be running, or the auth key was rejected"
fi
manual_checks
exit 3
