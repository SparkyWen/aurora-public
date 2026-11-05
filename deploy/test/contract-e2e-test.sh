#!/usr/bin/env bash
#
# The whole chain, for real: install.sh prints a link, the app's own Dart code expands
# it into a contract and compiles it to sing-box JSON, and then every selectable exit
# carries a real HTTPS request. If the installer and the app ever disagree about a
# field, this is the test that notices, because neither side is mocked.
#
# No root, no TUN, and no service, firewall or router changes: the node runs through
# the installer's test mode on high ports, and each compiled client config has its TUN
# inbound swapped for a local SOCKS inbound.
#
#   SING_BOX=/path/to/sing-box DART=/path/to/dart bash deploy/test/contract-e2e-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="${SING_BOX:-$(command -v sing-box || true)}"
DART="${DART:-$(command -v dart || true)}"
[[ -x "$SB" ]] || { echo "set SING_BOX=/path/to/sing-box" >&2; exit 2; }
[[ -x "$DART" ]] || { echo "set DART=/path/to/dart" >&2; exit 2; }

WORK="$(mktemp -d)"
PASS=0
FAIL=0
CLIENT_PID=""

cleanup() {
  if [[ -n "$CLIENT_PID" ]]; then kill "$CLIENT_PID" 2>/dev/null || true; fi
  pkill -f "sing-box run -c $WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

etc_of() {
  case "$(uname -s)" in
    Darwin) printf '%s/usr/local/etc/aurora-node' "$1" ;;
    *) printf '%s/etc/aurora-node' "$1" ;;
  esac
}

node() {
  local prefix="$1"
  shift
  AURORA_TEST_MODE=1 AURORA_PREFIX="$prefix" AURORA_SING_BOX="$SB" bash "$ROOT/install.sh" "$@" >/dev/null 2>&1
}

base=$((21000 + RANDOM % 20000))
VPS="$WORK/vps"
HOME_NODE="$WORK/home"
RELAY="$WORK/relay"

echo "--- standing up a VPS, a home node and a relay in front of it"
node "$VPS" --vps --name tokyo --host 127.0.0.1 --no-self-test --reality-sni www.apple.com \
  --reality-port "$base" --hy2-port "$((base + 1))" --ss-port "$((base + 2))"
node "$HOME_NODE" --home --name house --host 127.0.0.1 --no-upnp --no-self-test --reality-sni www.apple.com \
  --reality-port "$((base + 3))" --hy2-port "$((base + 4))" --ss-port "$((base + 5))"
node "$RELAY" relay "$(cat "$(etc_of "$HOME_NODE")/link.txt")" --name edge --host 127.0.0.1 \
  --no-self-test --reality-sni www.apple.com \
  --reality-port "$((base + 6))" --hy2-port "$((base + 7))" --ss-port "$((base + 8))"
pass "all three nodes installed"

echo "--- expanding the links with the app's own code"
contract="$WORK/contract.json"
(
  cd "$ROOT/app"
  "$DART" run tool/link_to_contract.dart "$contract" \
    "$(cat "$(etc_of "$VPS")/link.txt")" \
    "$(cat "$(etc_of "$HOME_NODE")/link.txt")" \
    "$(cat "$(etc_of "$RELAY")/link.txt")"
)
pass "links expand into one contract"

echo "--- compiling for every platform and validating with sing-box itself"
for platform in android ios desktop windows linux; do
  for mode in global smart; do
    config="$WORK/$platform-$mode.json"
    (cd "$ROOT/app" && "$DART" run tool/compile_check.dart "$contract" "$mode" "$config" "$platform" >/dev/null)
    if "$SB" check -c "$config" >/dev/null 2>"$WORK/check.log"; then
      pass "$platform/$mode passes sing-box check"
    else
      fail "$platform/$mode: $(tail -n 1 "$WORK/check.log")"
    fi
  done
done

echo "--- real traffic through every selectable exit"
EXPECTED="$(curl -fsS4 --max-time 10 https://api.ipify.org)"
python3 - "$WORK/android-global.json" "$WORK/exits.txt" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
outbounds = {o["tag"]: o for o in config["outbounds"]}
exits = [
    o["tag"]
    for o in config["outbounds"]
    if o["type"] in ("vless", "hysteria2", "shadowsocks") and "-entry-" not in o["tag"]
]
open(sys.argv[2], "w").write("\n".join(exits) + "\n")
PY
exit_count="$(wc -l <"$WORK/exits.txt" | tr -d ' ')"
if [[ "$exit_count" == 9 ]]; then
  pass "contract has 9 selectable exits (3 VPS, 3 home, 3 via relay)"
else
  fail "expected 9 selectable exits, found $exit_count"
fi

port=$((base + 20))
while read -r tag; do
  port=$((port + 1))
  client="$WORK/client-$tag.json"
  python3 - "$WORK/android-global.json" "$client" "$tag" "$port" "$WORK" <<'PY'
import json
import sys

source, target, tag, port, work = sys.argv[1:6]
config = json.load(open(source))
# Swap the TUN inbound for a local proxy so no privileges are needed. Everything else
# (outbounds, chaining, TLS pins, source-port hopping) is exactly what the app runs.
config["inbounds"] = [{"type": "socks", "tag": "test-in", "listen": "127.0.0.1", "listen_port": int(port)}]
route = config["route"]
route["rules"] = [r for r in route.get("rules", []) if r.get("action") not in ("sniff", "hijack-dns")]
route["final"] = tag
# Pin DNS to the exit under test too, so a failure cannot hide behind another leg.
config.pop("dns", None)
config["dns"] = {"servers": [{"type": "local", "tag": "local"}], "strategy": "ipv4_only"}
route["default_domain_resolver"] = {"server": "local"}
config.setdefault("experimental", {}).pop("clash_api", None)
config["experimental"].pop("cache_file", None)
json.dump(config, open(target, "w"))
PY
  "$SB" run -c "$client" >"$WORK/client-$tag.log" 2>&1 &
  CLIENT_PID=$!
  sleep 2
  actual=""
  for _ in 1 2 3; do
    actual="$(curl -fsS4 --max-time 15 --proxy "socks5h://127.0.0.1:$port" https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$actual" ]] && break
    sleep 1
  done
  if [[ "$actual" == "$EXPECTED" ]]; then
    pass "$tag carries traffic and exits where expected"
  elif [[ -n "$actual" ]]; then
    fail "$tag exits from an unexpected address"
  else
    fail "$tag carried no traffic: $(tail -n 2 "$WORK/client-$tag.log" | cut -c1-200)"
  fi
  kill "$CLIENT_PID" 2>/dev/null || true
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=""
done <"$WORK/exits.txt"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
