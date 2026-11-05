#!/usr/bin/env bash
# Prove where each selectable exit actually comes out.
#
# Usage:
#   scripts/verify-egress.sh --config <compiled sing-box json> --expect <ipv4>
#                            [--only <tag or glob>] [--sing-box <path>]
#                            [--port <n>] [--port-wait <seconds>]
#
# Compile a contract first (no root needed, and nothing here touches the system's
# routes, because each probe is a local proxy rather than a TUN):
#   cd app && dart run tool/compile_check.dart <contract.json> global compiled-global.json
#
# Then check every exit, or one server's exits at a time when your servers leave from
# different addresses. Exits are named after their server:
#   scripts/verify-egress.sh --config compiled-global.json --expect 203.0.113.81
#   scripts/verify-egress.sh --config compiled-global.json --expect 203.0.113.81 --only 'home-*'
#
# Why this exists: connectivity checks do not show where traffic leaves. A CDN-fronted
# route once passed every "can I reach this site" probe while quietly exiting at the CDN
# origin, because its entry node had been declared a terminal exit. That route looked
# healthy and was worse than a dead one. So this runs one temporary sing-box per exit,
# with route.final pinned to that exit, and compares the reflected address against the
# address you expected. It exits non-zero if any exit comes out anywhere else.
#
# Entry nodes are skipped: they are reachable only through another node's detour, so
# probing one measures the middle of a chain, not an exit.
#
# Environment: AURORA_SING_BOX, AURORA_PROBE_PORT, AURORA_PORT_WAIT,
# AURORA_REFLECTOR_URL, AURORA_HTTPS_204_URL, AURORA_REQUEST_TIMEOUT.
set -uo pipefail

CONFIG=''
EXPECT=''
SING_BOX="${AURORA_SING_BOX:-sing-box}"
PORT="${AURORA_PROBE_PORT:-21080}"
PORT_WAIT="${AURORA_PORT_WAIT:-20}"
REFLECTOR="${AURORA_REFLECTOR_URL:-https://api.ipify.org}"
HTTPS_204="${AURORA_HTTPS_204_URL:-https://www.gstatic.com/generate_204}"
TIMEOUT="${AURORA_REQUEST_TIMEOUT:-20}"
# The stub-based test needs to know which tag is in flight; harmless in prod.
TAG_FILE="${AURORA_EGRESS_TAG_FILE:-}"
ONLY=''

usage() {
  printf 'usage: %s --config <compiled sing-box json> --expect <ipv4> [--sing-box <path>] [--only <tag or glob>] [--port <n>] [--port-wait <n>]\n' "$0" >&2
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --sing-box) SING_BOX="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --port-wait) PORT_WAIT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -r "$CONFIG" && -n "$EXPECT" ]] || usage
[[ "$EXPECT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || usage
[[ "$PORT" =~ ^[0-9]+$ && "$PORT_WAIT" =~ ^[0-9]+$ ]] || usage

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Selector membership is the definition of "an exit the user can end up on".
TAGS="$(python3 -c '
import json
import sys

config = json.load(open(sys.argv[1]))
selectors = [o for o in config["outbounds"] if o["type"] == "selector"]
if not selectors:
    raise SystemExit("no selector in the compiled config")
print(" ".join(t for t in selectors[0]["outbounds"] if t != "auto"))
' "$CONFIG")" || {
  printf 'FAIL could not read selector membership\n' >&2
  exit 65
}
[[ -n "$TAGS" ]] || {
  printf 'FAIL the selector exposes no exits\n' >&2
  exit 65
}
if [[ -n "$ONLY" ]]; then
  selected=''
  for tag in $TAGS; do
    # Unquoted on purpose: --only is a glob, and an exact tag is a glob that matches itself.
    # shellcheck disable=SC2053
    [[ "$tag" == $ONLY ]] && selected="$selected $tag"
  done
  TAGS="$selected"
  # Reporting success after checking nothing would be the worst possible outcome here.
  [[ -n "$TAGS" ]] || {
    printf 'FAIL no exit in the selector matches %s\n' "$ONLY" >&2
    exit 65
  }
fi

PASS_COUNT=0
FAIL_COUNT=0

for tag in $TAGS; do
  probe="$TMP/probe-$tag.json"
  if ! python3 - "$CONFIG" "$tag" "$PORT" "$probe" <<'PY'
import json
import sys

source, tag, port, output = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
config = json.load(open(source))
# A local mixed inbound keeps the probe off the default route: a TUN probe would
# need root and would drag the whole machine through the outbound under test.
config["inbounds"] = [
    {"type": "mixed", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": port}
]
route = config.setdefault("route", {})
# Keep only the actions (sniff / hijack-dns) and the private-address shortcut;
# every routing rule that could steer traffic elsewhere has to go, or the run
# measures the rule instead of the pinned outbound.
route["rules"] = [
    rule for rule in route.get("rules", [])
    if "action" in rule or rule.get("ip_is_private")
]
route["final"] = tag
route.pop("auto_detect_interface", None)
config["experimental"] = {"cache_file": {"enabled": False}}
json.dump(config, open(output, "w"), ensure_ascii=False, indent=2)
PY
  then
    printf 'FAIL %s could-not-build-probe\n' "$tag"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  [[ -z "$TAG_FILE" ]] || printf '%s' "$tag" >"$TAG_FILE"
  "$SING_BOX" run -c "$probe" >"$TMP/$tag.log" 2>&1 &
  sing_box_pid=$!
  waited=0
  while (( waited < PORT_WAIT )); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 1
    waited=$((waited + 1))
  done

  egress="$(curl --silent --show-error --fail --max-time "$TIMEOUT" \
    --socks5-hostname "127.0.0.1:$PORT" "$REFLECTOR" 2>/dev/null | tr -d '[:space:]')"
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time "$TIMEOUT" --socks5-hostname "127.0.0.1:$PORT" "$HTTPS_204" 2>/dev/null)"

  kill "$sing_box_pid" 2>/dev/null
  wait "$sing_box_pid" 2>/dev/null

  if [[ "$egress" == "$EXPECT" ]]; then
    printf 'PASS %s egress=%s 204=%s\n' "$tag" "$egress" "${code:-none}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'FAIL %s egress=%s expected=%s 204=%s\n' \
      "$tag" "${egress:-unreachable}" "$EXPECT" "${code:-none}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

if (( FAIL_COUNT == 0 )); then
  printf 'OVERALL PASS exits=%d expected_egress=%s\n' "$PASS_COUNT" "$EXPECT"
else
  printf 'OVERALL FAIL pass=%d fail=%d expected_egress=%s\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$EXPECT"
fi
(( FAIL_COUNT == 0 ))
