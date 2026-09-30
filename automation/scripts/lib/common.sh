#!/usr/bin/env bash
# lib/common.sh: helpers shared by the DigitalOcean exit-node scripts.
#
# Sourced, never run directly. Works with the bash 3.2 that ships with macOS and
# needs only curl and python3 (both come with macOS; jq is deliberately not
# required so there is one code path everywhere).
#
# The one rule everything here follows: secrets never go on a command line.
# API tokens travel inside a curl config that curl reads from stdin (-K -),
# request bodies go through 0600 files in a private scratch directory, and the
# Tailscale auth key reaches python on stdin. Nothing ever runs with set -x.

DO_API="https://api.digitalocean.com/v2"
TS_API="https://api.tailscale.com/api/v2"
TS_ACCESS_TOKEN=""
CURRENT_STEP="starting"
TMP=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
_now()  { date '+%H:%M:%S'; }
log()   { printf '[%s] %s\n' "$(_now)" "$*" >&2; }
warn()  { printf '[%s] warning: %s\n' "$(_now)" "$*" >&2; }
die()   { printf '[%s] error: %s\n' "$(_now)" "$1" >&2; exit "${2:-1}"; }
# shellcheck disable=SC2034  # CURRENT_STEP is read by the scripts that source this file
step()  { CURRENT_STEP="$1"; log "==> $1"; }

# ---------------------------------------------------------------------------
# Preconditions and prompts
# ---------------------------------------------------------------------------
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

require_env() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "environment variable $v is not set (run with --help)"
  done
}

# need_arg FLAG VALUE...: dies unless the flag was followed by a value.
need_arg() {
  [ "$#" -ge 2 ] || die "$1 needs a value" 2
}

confirm() {
  local answer
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  printf '%s [y/N] ' "$1" >&2
  read -r answer || return 1
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Scratch directory: private to this user, wiped on exit
# ---------------------------------------------------------------------------
make_scratch() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/ts-exit.XXXXXX")" || die "could not create a scratch directory"
  chmod 700 "$TMP"
}

cleanup_scratch() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# JSON helpers (python3 standard library only)
# ---------------------------------------------------------------------------

# json_get PATH   (JSON document on stdin)
#   json_get 'droplet.networks.v4[0].ip_address' < response.json
# Prints the value: strings and numbers as-is, booleans as true/false, objects
# and arrays as JSON. Exit 1 if the path is missing or null, 2 if not JSON.
PY_JSON_GET='
import json, re, sys
path = sys.argv[1]
try:
    cur = json.load(sys.stdin)
except Exception:
    sys.exit(2)
for idx, key in re.findall(r"\[(\d+)\]|([^.\[\]]+)", path):
    try:
        cur = cur[int(idx)] if idx else cur[key]
    except (KeyError, IndexError, TypeError):
        sys.exit(1)
if cur is None:
    sys.exit(1)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
'
json_get() {
  python3 -c "$PY_JSON_GET" "$1"
}

# api_error_message FILE: the human-readable part of an error response.
api_error_message() {
  python3 - "$1" <<'PY'
import json, sys
try:
    raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    print("(no response body)")
    sys.exit()
try:
    d = json.loads(raw)
    print(d.get("message") or d.get("error") or raw[:300])
except Exception:
    print(raw[:300] or "(empty response)")
PY
}

# write_state FILE key value [key value ...]: merge fields into a small JSON
# record of what the scripts created. Never holds secrets.
write_state() {
  python3 - "$@" <<'PY'
import json, os, sys, time
path = sys.argv[1]
fields = dict(zip(sys.argv[2::2], sys.argv[3::2]))
existing = {}
if os.path.exists(path):
    try:
        existing = json.load(open(path))
    except Exception:
        existing = {}
existing.update({k: v for k, v in fields.items() if v})
existing["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
with open(path, "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")
PY
}

# ---------------------------------------------------------------------------
# HTTP: api_request METHOD URL TOKEN OUT_FILE [DATA_FILE]
#
# Writes the response body to OUT_FILE and prints the HTTP status code. The
# token and the body travel in a curl config on stdin, so neither shows up in
# the process list. Retries three times on network errors, 429 and 5xx.
# Returns 0 for any 2xx. Set API_CONTENT_TYPE to send something other than JSON.
# ---------------------------------------------------------------------------
api_request() {
  local method="$1" url="$2" token="$3" out="$4" datafile="${5:-}"
  local ctype="${API_CONTENT_TYPE:-application/json}"
  local attempt=1 code rc
  while :; do
    rc=0
    code="$(
      {
        printf 'url = "%s"\n' "$url"
        printf 'request = "%s"\n' "$method"
        if [ -n "$token" ]; then
          printf 'header = "Authorization: Bearer %s"\n' "$token"
        fi
        printf 'header = "Accept: application/json"\n'
        if [ -n "$datafile" ]; then
          printf 'header = "Content-Type: %s"\n' "$ctype"
          printf 'data-binary = "@%s"\n' "$datafile"
        fi
        printf 'output = "%s"\n' "$out"
        printf 'write-out = "%%{http_code}"\n'
        printf 'silent\nshow-error\nmax-time = 60\n'
      } | curl -K -
    )" || rc=$?
    case "$rc:$code" in
      0:2??)
        printf '%s\n' "$code"
        return 0 ;;
      0:429|0:5??|[1-9]*:*)
        if [ "$attempt" -lt 3 ]; then
          warn "request to $url failed (curl exit $rc, HTTP ${code:-none}); retrying in $((attempt * 3))s"
          sleep $((attempt * 3))
          attempt=$((attempt + 1))
          continue
        fi ;;
    esac
    printf '%s\n' "${code:-000}"
    return 1
  done
}

# do_api METHOD PATH OUT_FILE [DATA_FILE]   (PATH starts with /, e.g. /droplets)
do_api() {
  api_request "$1" "$DO_API$2" "$DIGITALOCEAN_TOKEN" "$3" "${4:-}"
}

# ts_api METHOD PATH OUT_FILE [DATA_FILE]   (needs ts_get_access_token first)
ts_api() {
  api_request "$1" "$TS_API$2" "$TS_ACCESS_TOKEN" "$3" "${4:-}"
}

# Sets TS_ACCESS_TOKEN from TS_API_KEY, or by exchanging an OAuth client id and
# secret for a one-hour access token. The secret only ever touches a 0600 file
# in the scratch directory and is removed right after the exchange.
ts_get_access_token() {
  if [ -n "${TS_API_KEY:-}" ]; then
    TS_ACCESS_TOKEN="$TS_API_KEY"
    return 0
  fi
  if [ -z "${TS_OAUTH_CLIENT_ID:-}" ] || [ -z "${TS_OAUTH_CLIENT_SECRET:-}" ]; then
    die "set TS_API_KEY, or TS_OAUTH_CLIENT_ID and TS_OAUTH_CLIENT_SECRET"
  fi
  local form="$TMP/oauth-form" resp="$TMP/oauth-resp.json" code
  printf 'client_id=%s&client_secret=%s' "$TS_OAUTH_CLIENT_ID" "$TS_OAUTH_CLIENT_SECRET" > "$form"
  code="$(API_CONTENT_TYPE=application/x-www-form-urlencoded api_request POST "$TS_API/oauth/token" "" "$resp" "$form")" \
    || die "Tailscale OAuth token request failed (HTTP $code): $(api_error_message "$resp")"
  TS_ACCESS_TOKEN="$(json_get access_token < "$resp")" || die "no access_token in the OAuth response"
  rm -f "$form" "$resp"
}

# ---------------------------------------------------------------------------
# Local Tailscale client
# ---------------------------------------------------------------------------

# Prints the path of a tailscale CLI: PATH first, then the macOS app bundle.
find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return 0
  fi
  if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    printf '%s\n' /Applications/Tailscale.app/Contents/MacOS/Tailscale
    return 0
  fi
  return 1
}

# tailscale_running BIN: true only when the client is connected. On macOS a
# stopped client still exits 0 from `tailscale status`, so check the JSON.
tailscale_running() {
  local state
  state="$("$1" status --json 2>/dev/null | json_get BackendState 2>/dev/null)" || return 1
  [ "$state" = "Running" ]
}

# droplet_public_ips FILE: prints "IPv4 IPv6" from a GET /droplets/{id}
# response, with "-" for an address that is not there yet.
droplet_public_ips() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["droplet"]
nets = d.get("networks") or {}
v4 = [n["ip_address"] for n in nets.get("v4", []) if n.get("type") == "public"]
v6 = [n["ip_address"] for n in nets.get("v6", []) if n.get("type") == "public"]
print((v4[0] if v4 else "-"), (v6[0] if v6 else "-"))
PY
}
