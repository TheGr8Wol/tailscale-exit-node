#!/usr/bin/env bash
# validate-local.sh
#
# Everything about this project that can be checked on a Mac with no cloud
# account and no droplet. Run it after editing anything under automation/ or
# site/. It never talks to DigitalOcean or Tailscale.
#
# Optional extras it will use if installed: shellcheck (brew install shellcheck)
# and OpenTofu or Terraform (brew install opentofu).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/automation/scripts"
PASS=0; FAIL=0; SKIP=0
ok()      { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
fail()    { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
skip()    { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$*"; }
section() { printf '\n%s\n' "$*"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_KEY="tskey-auth-DRYRUN-validate-x"

section "1. Scripts parse under /bin/bash (macOS ships 3.2)"
for f in "$SCRIPTS"/*.sh "$SCRIPTS"/lib/common.sh; do
  if /bin/bash -n "$f" 2> "$TMP/err"; then ok "$(basename "$f")"; else fail "$(basename "$f"): $(cat "$TMP/err")"; fi
done

section "2. shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s bash -x -P "$SCRIPTS" "$SCRIPTS"/*.sh "$SCRIPTS"/lib/common.sh > "$TMP/sc.out" 2>&1; then
    ok "no findings"
  else
    fail "findings (see below)"; cat "$TMP/sc.out"
  fi
else
  skip "shellcheck not installed (brew install shellcheck)"
fi

section "3. Offline dry run of provision-digitalocean.sh"
mkdir -p "$TMP/state"
if TS_AUTHKEY="$FAKE_KEY" /bin/bash "$SCRIPTS/provision-digitalocean.sh" --offline --name validate-test \
     --state-dir "$TMP/state" --render-out "$TMP/user-data.yaml" > "$TMP/dry.out" 2> "$TMP/dry.err"; then
  ok "exit 0"
  if grep -q '"user_data": "<[0-9]* bytes, redacted>"' "$TMP/dry.out"; then ok "user_data is redacted in the summary"; else fail "summary does not redact user_data"; cat "$TMP/dry.out"; fi
  if grep -q "$FAKE_KEY" "$TMP/dry.out" "$TMP/dry.err"; then fail "the auth key leaked into script output"; else ok "auth key never printed"; fi
  if grep -q '"ipv6": true' "$TMP/dry.out"; then ok "IPv6 requested"; else fail "IPv6 not requested"; fi
  if [ -z "$(ls -A "$TMP/state")" ]; then ok "dry run wrote no state"; else fail "dry run wrote state files"; fi
else
  fail "exit $? (stderr below)"; cat "$TMP/dry.err"
fi
if TS_AUTHKEY="not-a-key" /bin/bash "$SCRIPTS/provision-digitalocean.sh" --offline --name validate-test --state-dir "$TMP/state" > /dev/null 2>&1; then
  fail "a malformed TS_AUTHKEY was accepted"
else
  ok "a malformed TS_AUTHKEY is refused"
fi
if /bin/bash "$SCRIPTS/provision-digitalocean.sh" --offline --name "Bad_Name" --state-dir "$TMP/state" > /dev/null 2>&1; then
  fail "an invalid --name was accepted"
else
  ok "an invalid --name is refused"
fi
if /bin/bash "$SCRIPTS/provision-digitalocean.sh" --offline --render-out "$TMP/x" --no-such-flag > /dev/null 2>&1; then
  fail "an unknown flag was accepted"
else
  ok "an unknown flag is refused"
fi

section "4. Rendered cloud-init file"
if [ -f "$TMP/user-data.yaml" ]; then
  if [ "$(head -n 1 "$TMP/user-data.yaml")" = "#cloud-config" ]; then ok "starts with #cloud-config"; else fail "first line is not #cloud-config"; fi
  # shellcheck disable=SC2016
  if grep -qF '${' "$TMP/user-data.yaml"; then fail "unfilled placeholder remains"; else ok "no placeholders left"; fi
  if grep -q -- '--advertise-tags=tag:exit --advertise-exit-node --ssh --hostname=validate-test' "$TMP/user-data.yaml"; then ok "tailscale up line has tag, exit node, ssh and hostname"; else fail "tailscale up line is wrong"; fi
  if /usr/bin/ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' "$TMP/user-data.yaml" > "$TMP/user-data.json" 2> "$TMP/err"; then
    ok "parses as YAML (ruby psych)"
    if python3 - "$TMP/user-data.json" "$FAKE_KEY" <<'PY'
import base64, json, sys
doc = json.load(open(sys.argv[1]))
entry = [w for w in doc.get("write_files", []) if w.get("path") == "/run/tailscale-authkey"]
if not entry:
    sys.exit("no /run/tailscale-authkey entry")
if entry[0].get("encoding") != "b64" or entry[0].get("permissions") != "0600":
    sys.exit("key file entry must be b64 with permissions 0600")
if base64.b64decode(entry[0]["content"]).decode() != sys.argv[2]:
    sys.exit("base64 round trip does not give the key back")
paths = [w.get("path") for w in doc.get("write_files", [])]
for p in ("/etc/sysctl.d/99-tailscale.conf", "/etc/networkd-dispatcher/routable.d/50-tailscale"):
    if p not in paths:
        sys.exit("missing write_files entry " + p)
if doc.get("ssh_pwauth") is not False:
    sys.exit("ssh_pwauth should be false")
if not any("shred" in str(c) for c in doc.get("runcmd", [])):
    sys.exit("runcmd never shreds the key file")
PY
    then ok "key round-trips through base64; required files and commands present"; else fail "content check failed"; fi
  else
    fail "does not parse as YAML: $(cat "$TMP/err")"
  fi
else
  skip "no rendered file (dry run failed)"
fi

section "5. Policy files are valid HuJSON"
for f in "$ROOT"/automation/policy/*.hujson; do
  if python3 - "$f" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out, i, n = [], 0, len(src)
while i < n:                       # strip // and /* */ comments outside strings
    c = src[i]
    if c == '"':
        j = i + 1
        while j < n and src[j] != '"':
            j += 2 if src[j] == "\\" else 1
        out.append(src[i:j + 1]); i = j + 1
    elif src.startswith("//", i):
        i = src.find("\n", i); i = n if i < 0 else i
    elif src.startswith("/*", i):
        i = src.find("*/", i + 2) + 2
    else:
        out.append(c); i += 1
text = re.sub(r",(\s*[}\]])", r"\1", "".join(out))   # trailing commas
doc = json.loads(text)
for key in ("tagOwners", "autoApprovers"):
    if key not in doc:
        sys.exit("missing " + key)
if doc["autoApprovers"].get("exitNode") != ["tag:exit"]:
    sys.exit("autoApprovers.exitNode should be [tag:exit]")
if "tag:exit" not in doc["tagOwners"]:
    sys.exit("tagOwners has no tag:exit")
PY
  then ok "$(basename "$f")"; else fail "$(basename "$f")"; fi
done

section "6. Terraform"
TF=""
command -v tofu >/dev/null 2>&1 && TF=tofu
[ -z "$TF" ] && command -v terraform >/dev/null 2>&1 && TF=terraform
if [ -z "$TF" ]; then
  skip "tofu/terraform not installed (brew install opentofu)"
elif ! ls "$ROOT"/automation/terraform/*.tf >/dev/null 2>&1; then
  skip "no .tf files yet"
else
  (
    cd "$ROOT/automation/terraform" || exit 1
    if "$TF" fmt -check -diff > "$TMP/fmt.out" 2>&1; then ok "$TF fmt"; else fail "$TF fmt (run: $TF fmt)"; cat "$TMP/fmt.out"; fi
    if "$TF" init -backend=false -input=false > "$TMP/init.out" 2>&1; then
      ok "$TF init"
      if "$TF" validate > "$TMP/validate.out" 2>&1; then ok "$TF validate"; else fail "$TF validate"; cat "$TMP/validate.out"; fi
    else
      fail "$TF init (needs network to fetch providers)"; tail -20 "$TMP/init.out"
    fi
  )
fi

section "7. Web page"
if [ -f "$ROOT/site/index.html" ]; then
  if python3 - "$ROOT/site/index.html" <<'PY'
import re, sys
from html.parser import HTMLParser
src = open(sys.argv[1], encoding="utf-8").read()
low = src.lower()
m = re.search(r"<!doctype|<(?:html|head|body)[\s>]", low)
if m:
    sys.exit("must not contain %s: the artifact host adds the page skeleton" % m.group(0).strip())
if "<title>" not in low[:8192]:
    sys.exit("no <title> in the first 8 KB")
for host in ("http://", "https://"):
    for m in re.finditer(r'(src|href)=["\'](%s[^"\']+)' % host, src):
        url = m.group(2)
        if m.group(1) == "src" and not url.startswith("https://cdnjs.cloudflare.com"):
            sys.exit("external script/asset not allowed: " + url)
VOID = {"area","base","br","col","embed","hr","img","input","link","meta","source","track","wbr"}
class P(HTMLParser):
    def __init__(self):
        super().__init__(); self.stack = []; self.errors = []
    def handle_starttag(self, tag, attrs):
        if tag not in VOID: self.stack.append((tag, self.getpos()[0]))
    def handle_endtag(self, tag):
        if tag in VOID: return
        if not self.stack or self.stack[-1][0] != tag:
            self.errors.append("unexpected </%s> at line %d (open: %s)" % (tag, self.getpos()[0], self.stack[-1][0] if self.stack else "none"))
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i][0] == tag:
                    del self.stack[i:]; break
        else:
            self.stack.pop()
p = P(); p.feed(src)
if p.errors: sys.exit("\n".join(p.errors[:10]))
if p.stack: sys.exit("unclosed tags: " + ", ".join("%s (line %d)" % t for t in p.stack[:10]))
size = len(src.encode())
if size > 2_000_000: sys.exit("page is %d bytes; keep it small" % size)
print("  info  %d KB, tags balanced" % (size // 1024))
PY
  then ok "site/index.html structure"; else fail "site/index.html structure"; fi
else
  skip "site/index.html not written yet"
fi

section "8. Local links in Markdown"
if python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for dirpath, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if not d.startswith(".") and d != "site"]
    for fn in files:
        if not fn.endswith(".md"): continue
        path = os.path.join(dirpath, fn)
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(r"\]\(([^)\s]+)\)", text):
            target = m.group(1)
            if re.match(r"^[a-z]+:", target) or target.startswith("#"): continue
            target = target.split("#")[0]
            if target and not os.path.exists(os.path.normpath(os.path.join(dirpath, target))):
                bad.append("%s -> %s" % (os.path.relpath(path, root), m.group(1)))
if bad: sys.exit("\n".join(bad))
PY
then ok "all local links resolve"; else fail "broken local links (above)"; fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
