#!/usr/bin/env bash
# Dry-run checks for deploy/extras/hy2-port-hopping.sh. Changes nothing on this machine:
# every run passes --dry-run, or fails before reaching any system command.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/deploy/extras/hy2-port-hopping.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

cat >"$TMP/node.env" <<'ENV'
S_MODE='vps'
S_HY2_PORT='8443'
S_SS_PORT='2053'
S_HY2_PASS='PLACEHOLDER-MUST-NOT-APPEAR'
ENV

run() { AURORA_NODE_ENV="$TMP/node.env" bash "$SCRIPT" "$@" 2>&1; }

output="$(run --range 20000-29999 --dry-run)" || fail "valid dry run failed: $output"
grep -q 'udp dport 20000-29999 redirect to :8443' <<<"$output" ||
  fail "the port did not come from the state file: $output"
grep -q 'PLAN redirect=udp/20000-29999->8443' <<<"$output" || fail "missing plan: $output"
if grep -q 'PLACEHOLDER-MUST-NOT-APPEAR' <<<"$output"; then
  fail 'a credential from the state file was printed'
fi
# The warning is the point of the script: it must say how to check before advertising.
grep -q 'NOT using this range' <<<"$output" || fail "missing warning: $output"
grep -q "tcpdump -ni eth0 'udp and portrange 20000-29999'" <<<"$output" ||
  fail "missing capture command: $output"
grep -q 'nc -u -w1 YOUR_SERVER_ADDRESS' <<<"$output" || fail "missing probe command: $output"
grep -q 'for p in 20000 24999 29999' <<<"$output" || fail "probes do not span the range: $output"
grep -q '"server_ports": \["8443:8443", "20000:29999"\]' <<<"$output" ||
  fail "missing advertise snippet: $output"

output="$(run --uninstall --dry-run)" || fail "uninstall dry run failed: $output"
grep -q 'PLAN delete-nft-table=inet/aurora_hy2_hop' <<<"$output" || fail "missing uninstall plan: $output"

refused() {
  local label="$1" expected="$2" output
  shift 2
  if output="$(run "$@")"; then
    fail "$label was accepted: $output"
  fi
  grep -q "$expected" <<<"$output" || fail "$label: wrong error: $output"
}

refused 'a malformed range' 'must look like' --range 20000 --dry-run
refused 'a reversed range' 'ascending' --range 29999-20000 --dry-run
refused 'a privileged range' 'must look like' --range 80-90 --dry-run
refused "Tailscale's port" 'Tailscale' --range 40000-42000 --dry-run
refused 'the Hysteria2 port' 'Hysteria2 port' --range 8000-9000 --dry-run
refused 'the Shadowsocks port' 'Shadowsocks port' --range 2000-3000 --dry-run
refused 'an uninstall with a range' 'takes no range' --uninstall --range 20000-29999 --dry-run

if AURORA_NODE_ENV="$TMP/missing.env" bash "$SCRIPT" --range 20000-29999 --dry-run >"$TMP/out" 2>&1; then
  fail 'ran without a state file'
fi
grep -q 'install.sh' "$TMP/out" || fail 'a missing state file should point at install.sh'

printf 'S_HY2_PORT=not-a-port\n' >"$TMP/bad.env"
if AURORA_NODE_ENV="$TMP/bad.env" bash "$SCRIPT" --range 20000-29999 --dry-run >"$TMP/out" 2>&1; then
  fail 'accepted a state file with no valid port'
fi

printf 'PASS hy2-port-hopping\n'
