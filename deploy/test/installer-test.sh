#!/usr/bin/env bash
#
# End-to-end tests for install.sh. Needs a sing-box binary and internet access, but
# never root: AURORA_TEST_MODE confines the installer to a temp prefix and runs the
# real sing-box as a child process on high ports. Services, firewalls and the router
# are not touched, so this is safe on a machine that is already a production node.
#
#   SING_BOX=/path/to/sing-box bash deploy/test/installer-test.sh
#
# What it proves: real HTTPS requests flow through REALITY, Hysteria2 and Shadowsocks;
# re-runs keep credentials; rotation replaces them; a relay reaches the home node and
# nothing else; and bad input is refused.
# check() evals its condition string, so shellcheck cannot see these variables being read.
# shellcheck disable=SC2034,SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="${SING_BOX:-$(command -v sing-box || true)}"
[[ -x "$SB" ]] || { echo "set SING_BOX=/path/to/sing-box" >&2; exit 2; }

WORK="$(mktemp -d)"
PASS=0
FAIL=0
HOME_PREFIX="$WORK/home"
RELAY_PREFIX="$WORK/relay"
VPS_PREFIX="$WORK/vps"

cleanup() {
  local prefix
  for prefix in "$VPS_PREFIX" "$HOME_PREFIX" "$RELAY_PREFIX"; do
    AURORA_TEST_MODE=1 AURORA_PREFIX="$prefix" AURORA_SING_BOX="$SB" \
      bash "$ROOT/install.sh" uninstall --purge >/dev/null 2>&1 || true
    if [[ -f "$prefix/pid" ]]; then kill "$(cat "$prefix/pid")" 2>/dev/null || true; fi
  done
  # Anything still rooted in our temp prefix is ours by construction.
  pkill -f "sing-box run -c $WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

node() {
  local prefix="$1"
  shift
  AURORA_TEST_MODE=1 AURORA_PREFIX="$prefix" AURORA_SING_BOX="$SB" bash "$ROOT/install.sh" "$@"
}

etc_of() {
  case "$(uname -s)" in
    Darwin) printf '%s/usr/local/etc/aurora-node' "$1" ;;
    *) printf '%s/etc/aurora-node' "$1" ;;
  esac
}

stop_node() {
  local pid_file
  pid_file="$(etc_of "$1")/test-service.pid"
  if [[ -f "$pid_file" ]]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
  fi
}

decode_link() {
  local value="${1#aurora://v1/}" pad
  value="${value%%#*}"
  value="$(printf '%s' "$value" | tr -- '-_' '+/')"
  pad=$(((4 - ${#value} % 4) % 4))
  while ((pad > 0)); do value="$value="; pad=$((pad - 1)); done
  printf '%s' "$value" | openssl enc -base64 -d -A
}

json_has() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); [d.__getitem__(k) for k in sys.argv[2:]]' "$@" >/dev/null 2>&1; }

base_port=$((21000 + RANDOM % 20000))
vps_ports=(--reality-port "$base_port" --hy2-port "$((base_port + 1))" --ss-port "$((base_port + 2))")
home_ports=(--reality-port "$((base_port + 10))" --hy2-port "$((base_port + 11))" --ss-port "$((base_port + 12))")
relay_ports=(--reality-port "$((base_port + 20))" --hy2-port "$((base_port + 21))" --ss-port "$((base_port + 22))")

echo "--- input validation"
out="$(node "$WORK/bad" --vps --name 'Bad Name' 2>&1 || true)"
check "rejects an invalid node name" '[[ "$out" == *"invalid --name"* ]]'
out="$(node "$WORK/bad" --vps --host 'not a host' 2>&1 || true)"
check "rejects an invalid host" '[[ "$out" == *"invalid --host"* ]]'
out="$(node "$WORK/bad" relay 'https://example.com' 2>&1 || true)"
check "relay rejects a non-aurora link" '[[ "$out" == *"expected an aurora"* ]]'
out="$(node "$WORK/bad" relay 'aurora://v1/!!!not-base64' 2>&1 || true)"
check "relay rejects an undecodable link" '[[ "$out" == *"could not be decoded"* ]]'
# node.env is sourced by a root process, so a crafted link must not reach it.
evil_json='{"v":1,"kind":"home","name":"house","host":"$(touch /tmp/aurora-pwned)","reality":{},"hy2":{},"ss":{"port":2053,"password":"x"}}'
evil_link="aurora://v1/$(printf '%s' "$evil_json" | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')"
out="$(node "$WORK/bad" relay "$evil_link" 2>&1 || true)"
check "relay refuses a link with shell syntax in its address" '[[ "$out" == *"no valid address"* && ! -e /tmp/aurora-pwned ]]'
evil_json="{\"v\":1,\"kind\":\"home\",\"name\":\"house\",\"host\":\"home.example.net\",\"reality\":{},\"hy2\":{},\"ss\":{\"port\":2053,\"password\":\"x';touch /tmp/aurora-pwned;'\"}}"
evil_link="aurora://v1/$(printf '%s' "$evil_json" | openssl enc -base64 -A | tr '+/' '-_' | tr -d '=')"
out="$(node "$WORK/bad" relay "$evil_link" 2>&1 || true)"
check "relay refuses a link with shell syntax in its password" '[[ "$out" == *"no Shadowsocks password"* && ! -e /tmp/aurora-pwned ]]'
out="$(node "$WORK/bad" --vps --host home.example.net --cf-token "x';touch /tmp/aurora-pwned;'" 2>&1 || true)"
check "refuses a DNS token with shell syntax" '[[ "$out" == *"unexpected characters"* && ! -e /tmp/aurora-pwned ]]'
out="$(node "$WORK/bad" --bogus-flag 2>&1 || true)"
check "rejects unknown options" '[[ "$out" == *"unknown option"* ]]'
out="$(node "$WORK/bad" --vps --duckdns-token abc --host home.example.net 2>&1 || true)"
check "duckdns requires a duckdns host" '[[ "$out" == *"duckdns.org"* ]]'
out="$(node "$WORK/bad" --vps --cf-token abc --host 203.0.113.9 2>&1 || true)"
check "dynamic DNS requires a DNS name" '[[ "$out" == *"DNS name"* ]]'

echo "--- VPS install: real traffic through all three protocols"
out="$(node "$VPS_PREFIX" --vps --name tokyo --host 203.0.113.10 "${vps_ports[@]}" 2>&1)" && code=0 || code=$?
check "install succeeds with a passing self-test" '[[ "$code" == 0 ]]'
check "REALITY carried a real request" '[[ "$out" == *"reality carries traffic"* ]]'
check "Hysteria2 carried a real request" '[[ "$out" == *"hy2 carries traffic"* ]]'
check "Shadowsocks carried a real request" '[[ "$out" == *"ss carries traffic"* ]]'
check "a camouflage target was chosen by test" '[[ "$out" == *"REALITY camouflage target:"* ]]'

etc="$(etc_of "$VPS_PREFIX")"
link="$(cat "$etc/link.txt")"
json="$(decode_link "$link")"
check "link is a v1 aurora link named after the node" '[[ "$link" == aurora://v1/*#tokyo ]]'
check "link stays short enough for a terminal QR code" '[[ ${#link} -lt 800 ]]'
check "bundle carries every protocol" 'json_has "$json" reality hy2 ss host name kind v'
check "bundle uses the requested address" '[[ "$json" == *"\"host\":\"203.0.113.10\""* ]]'
check "server config passes sing-box check" '"$SB" check -c "$etc/sing-box.json"'
mode_of() { if [[ "$(uname -s)" == Darwin ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi; }
check "master state file is private" '[[ "$(mode_of "$etc/node.env")" == 600 ]]'
check "link file is private" '[[ "$(mode_of "$etc/link.txt")" == 600 ]]'
check "TLS key is not world-readable" '[[ "$(mode_of "$etc/hy2.key")" != *[1-7] ]]'
stripped="$(printf '%s' "$out" | sed -E 's#aurora://v1/[A-Za-z0-9_-]+##')"
private_key="$(sed -n "s/^S_PRIVATE_KEY='\(.*\)'/\1/p" "$etc/node.env")"
hy2_pass="$(sed -n "s/^S_HY2_PASS='\(.*\)'/\1/p" "$etc/node.env")"
check "console output never prints the private key" '[[ "$stripped" != *"$private_key"* ]]'
check "console output never prints passwords outside the link" '[[ "$stripped" != *"$hy2_pass"* ]]'

echo "--- exit policy"
check "exit node refuses private destinations" 'grep -q "ip_is_private" "$etc/sing-box.json"'
check "exit node refuses SMTP" 'grep -q "\"port\": \[ 25 \]" "$etc/sing-box.json"'

echo "--- idempotence and rotation"
before="$(cat "$etc/node.env" | grep -E '^S_(UUID|PRIVATE_KEY|HY2_PASS|SS_PASS)=')"
stop_node "$VPS_PREFIX"
out="$(node "$VPS_PREFIX" --no-self-test 2>&1)"
after="$(cat "$etc/node.env" | grep -E '^S_(UUID|PRIVATE_KEY|HY2_PASS|SS_PASS)=')"
check "re-run keeps credentials" '[[ "$before" == "$after" ]]'
check "re-run keeps the published link" '[[ "$link" == "$(cat "$etc/link.txt")" ]]'
check "re-run says it reused credentials" '[[ "$out" == *"reusing existing credentials"* ]]'
stop_node "$VPS_PREFIX"
out="$(node "$VPS_PREFIX" --rotate --no-self-test 2>&1)"
after="$(cat "$etc/node.env" | grep -E '^S_(UUID|PRIVATE_KEY|HY2_PASS|SS_PASS)=')"
check "--rotate replaces credentials" '[[ "$before" != "$after" ]]'
check "--rotate publishes a new link" '[[ "$link" != "$(cat "$etc/link.txt")" ]]'
stop_node "$VPS_PREFIX"

echo "--- CDN option"
out="$(node "$WORK/cdn" --vps --name cdntest --host 203.0.113.11 \
  --reality-port "$((base_port + 30))" --hy2-port "$((base_port + 31))" --ss-port "$((base_port + 32))" \
  --cdn-domain cdn.example.com --cdn-port 8443 --reality-sni www.apple.com --no-self-test 2>&1)" && code=0 || code=$?
check "CDN install succeeds" '[[ "$code" == 0 ]]'
json="$(decode_link "$(cat "$(etc_of "$WORK/cdn")/link.txt")")"
check "bundle carries the CDN entry" 'json_has "$json" cdn'
check "server has a WebSocket inbound" 'grep -q "\"type\": \"ws\"" "$(etc_of "$WORK/cdn")/sing-box.json"'
stop_node "$WORK/cdn"
out="$(node "$WORK/cdnbad" --vps --name bad --host 203.0.113.11 \
  --reality-port "$((base_port + 33))" --hy2-port "$((base_port + 34))" --ss-port "$((base_port + 35))" \
  --cdn-domain cdn.example.com --cdn-port "$((base_port + 36))" --reality-sni www.apple.com --no-self-test 2>&1 || true)"
check "refuses a port Cloudflare cannot proxy" '[[ "$out" == *"not a port Cloudflare proxies"* ]]'

echo "--- home node plus relay chain: real traffic, restricted payload"
out="$(node "$HOME_PREFIX" --home --name house --host 127.0.0.1 --no-upnp "${home_ports[@]}" --no-self-test 2>&1)" && code=0 || code=$?
check "home install succeeds" '[[ "$code" == 0 ]]'
home_link="$(cat "$(etc_of "$HOME_PREFIX")/link.txt")"
check "bundle says this is a home node" '[[ "$(decode_link "$home_link")" == *"\"kind\":\"home\""* ]]'
out="$(node "$RELAY_PREFIX" relay "$home_link" --name edge --host 203.0.113.12 "${relay_ports[@]}" 2>&1)" && code=0 || code=$?
check "relay install and chain self-test succeed" '[[ "$code" == 0 ]]'
check "traffic passes relay then home over REALITY" '[[ "$out" == *"reality carries traffic"* ]]'
check "traffic passes relay then home over Hysteria2" '[[ "$out" == *"hy2 carries traffic"* ]]'
check "traffic passes relay then home over Shadowsocks" '[[ "$out" == *"ss carries traffic"* ]]'
check "relay refused the open internet" '[[ "$out" == *"relay rejects everything except the home node"* ]]'
relay_json="$(decode_link "$(cat "$(etc_of "$RELAY_PREFIX")/link.txt")")"
check "relay bundle carries its exit" '[[ "$relay_json" == *"\"exit\":{\"name\":\"house\""* ]]'
out="$(node "$WORK/relay2" relay "$(cat "$(etc_of "$RELAY_PREFIX")/link.txt")" --no-self-test 2>&1 || true)"
check "a relay cannot chain onto another relay" '[[ "$out" == *"relay'"'"'s link"* ]]'

echo "--- relay re-run"
relay_before="$(cat "$(etc_of "$RELAY_PREFIX")/link.txt")"
stop_node "$RELAY_PREFIX"
out="$(node "$RELAY_PREFIX" --no-self-test 2>&1)" && code=0 || code=$?
check "a relay re-run needs no link" '[[ "$code" == 0 ]]'
check "a relay re-run keeps its link" '[[ "$relay_before" == "$(cat "$(etc_of "$RELAY_PREFIX")/link.txt")" ]]'

echo "--- directory permissions the service user depends on"
lib_dir="$VPS_PREFIX/usr/local/lib/aurora-node"
check "the binary directory is traversable by other users" '[[ "$(mode_of "$lib_dir")" == 755 ]]'

echo "--- uninstall"
stop_node "$RELAY_PREFIX"
node "$RELAY_PREFIX" uninstall >/dev/null 2>&1
check "uninstall keeps keys by default" '[[ -f "$(etc_of "$RELAY_PREFIX")/node.env" ]]'
node "$RELAY_PREFIX" uninstall --purge >/dev/null 2>&1
check "uninstall --purge deletes keys" '[[ ! -e "$(etc_of "$RELAY_PREFIX")" ]]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
