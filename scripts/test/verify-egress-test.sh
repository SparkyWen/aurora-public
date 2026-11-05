#!/usr/bin/env bash
# A CDN-fronted route once shipped after being verified for connectivity and never for
# where it came out. This pins the checker that closes that gap: it must pin one
# outbound at a time and fail on any exit whose address is not the expected one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/verify-egress.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

HOME_IP=198.51.100.7
FOREIGN_IP=203.0.113.9

cat >"$TMP/compiled.json" <<'JSON'
{
  "log": {"level": "info"},
  "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"]}],
  "outbounds": [
    {"type": "selector", "tag": "proxy", "outbounds": ["auto", "exit-good", "exit-bad"]},
    {"type": "urltest", "tag": "auto", "outbounds": ["exit-good", "exit-bad"]},
    {"type": "vless", "tag": "entry-node", "server": "cdn.example.com", "server_port": 2053},
    {"type": "shadowsocks", "tag": "exit-good", "server": "home.example.net", "server_port": 2053, "detour": "entry-node"},
    {"type": "shadowsocks", "tag": "exit-bad", "server": "vps.example.net", "server_port": 2053},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"action": "sniff"}], "final": "proxy", "auto_detect_interface": true}
}
JSON

# Stubs stand in for the network: the checker's job is the config surgery and
# the verdict, and both are observable without leaving the box.
STUB="$TMP/stub"
mkdir -p "$STUB" "$TMP/seen"
cat >"$STUB/sing-box" <<STUBSB
#!/usr/bin/env bash
config=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == "-c" ]] && config="\$2"
  shift
done
cp "\$config" "$TMP/seen/\$(basename "\$config")"
while :; do sleep 1; done
STUBSB
chmod +x "$STUB/sing-box"

write_curl_stub() {
  cat >"$STUB/curl" <<STUBCURL
#!/usr/bin/env bash
# The tag under test is recorded by the checker before it probes.
tag="\$(cat "$TMP/current-tag" 2>/dev/null)"
case "\$*" in
  *generate_204*) printf '204' ;;
  *) if [[ "\$tag" == "exit-bad" ]]; then printf '%s' "$1"; else printf '%s' "$HOME_IP"; fi ;;
esac
STUBCURL
  chmod +x "$STUB/curl"
}

run_checker() {
  PATH="$STUB:$PATH" AURORA_EGRESS_TAG_FILE="$TMP/current-tag" \
    bash "$SCRIPT" --config "$TMP/compiled.json" --expect "$HOME_IP" \
    --sing-box "$STUB/sing-box" --port-wait 1 2>&1
}

# 1. Every exit lands on the expected address -> PASS, exit 0.
write_curl_stub "$HOME_IP"
output="$(run_checker)" || fail "all-home run should have succeeded: $output"
grep -q 'PASS exit-good' <<<"$output" || fail "exit-good not reported PASS: $output"
grep -q 'PASS exit-bad' <<<"$output" || fail "exit-bad not reported PASS: $output"
grep -q 'OVERALL PASS' <<<"$output" || fail "missing overall verdict: $output"

# 2. The regression shape: one exit comes out somewhere else -> FAIL, nonzero.
write_curl_stub "$FOREIGN_IP"
if output="$(run_checker)"; then
  fail "a foreign egress was accepted: $output"
fi
grep -q "FAIL exit-bad .*$FOREIGN_IP" <<<"$output" ||
  fail "the offending exit and its real egress were not named: $output"
grep -q 'PASS exit-good' <<<"$output" || fail "good exit misreported: $output"
grep -q 'OVERALL FAIL' <<<"$output" || fail "missing overall verdict: $output"

# 3. Each probe must actually pin its own outbound, or the run proves nothing:
#    every tag would just ride whatever the selector happened to pick.
for tag in exit-good exit-bad; do
  probe="$(ls "$TMP/seen" | grep -- "$tag" | head -1)"
  [[ -n "$probe" ]] || fail "no probe config was written for $tag"
  python3 - "$TMP/seen/$probe" "$tag" <<'PY' || fail "probe config for $tag is wrong"
import json
import sys

config = json.load(open(sys.argv[1]))
tag = sys.argv[2]
assert config["route"]["final"] == tag, config["route"]["final"]
inbounds = config["inbounds"]
assert len(inbounds) == 1 and inbounds[0]["type"] == "mixed", inbounds
assert inbounds[0]["listen"] == "127.0.0.1", inbounds[0]
# A TUN probe would need root and would capture the whole box; a selector left
# in place would let sing-box drift off the pinned outbound.
assert not any(o["type"] == "tun" for o in inbounds), inbounds
PY
done

# 4. Entries are transports, not exits: probing one measures the wrong hop.
ls "$TMP/seen" | grep -q 'entry-node' && fail 'an entry node was probed as an exit'

# 5. --only narrows the run by glob, so servers with different addresses can be checked
#    one at a time, and it never treats a typo as success.
rm -f "$TMP"/seen/*
write_curl_stub "$HOME_IP"
output="$(PATH="$STUB:$PATH" AURORA_EGRESS_TAG_FILE="$TMP/current-tag" \
  bash "$SCRIPT" --config "$TMP/compiled.json" --expect "$HOME_IP" \
  --sing-box "$STUB/sing-box" --port-wait 1 --only 'exit-g*' 2>&1)" ||
  fail "a glob run should have succeeded: $output"
grep -q 'PASS exit-good' <<<"$output" || fail "exit-good not probed: $output"
grep -q 'exit-bad' <<<"$output" && fail "--only did not exclude exit-bad: $output"

if output="$(PATH="$STUB:$PATH" bash "$SCRIPT" --config "$TMP/compiled.json" \
  --expect "$HOME_IP" --sing-box "$STUB/sing-box" --port-wait 1 --only 'no-such-exit' 2>&1)"; then
  fail "a filter matching nothing reported success: $output"
fi
grep -q 'no exit in the selector matches' <<<"$output" || fail "wrong error: $output"

printf 'PASS verify-egress\n'
