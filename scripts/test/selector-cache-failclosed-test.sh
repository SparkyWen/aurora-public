#!/usr/bin/env bash
set -euo pipefail

# Regression for a real outage: sing-box persists selector choices whenever
# cache_file is enabled. If `proxy -> fail-closed` survives a process restart, the new
# TUN connects successfully but every public flow is blocked before Aurora's command
# channel becomes ready. This is why ConfigCompiler turns cache_file off for multi-path
# contracts.
#
# Runs a real sing-box on high loopback ports. Set SING_BOX=/path/to/sing-box if it is
# not on PATH.

SING_BOX="${SING_BOX:-sing-box}"
TMP="$(mktemp -d)"
BOX_PID=''
base_port=$((42000 + ($$ % 1000) * 2))
api_port="$base_port"
mixed_port=$((base_port + 1))

cleanup() {
  if [[ -n "$BOX_PID" ]] && kill -0 "$BOX_PID" 2>/dev/null; then
    kill "$BOX_PID" 2>/dev/null || true
    wait "$BOX_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

write_config() {
  local enabled="$1" destination="$2"
  jq -n \
    --argjson enabled "$enabled" \
    --arg cache "$TMP/cache.db" \
    --arg controller "127.0.0.1:$api_port" \
    --argjson mixed_port "$mixed_port" \
    '{
      log: {level: "error", timestamp: false},
      inbounds: [{
        type: "mixed", tag: "mixed", listen: "127.0.0.1",
        listen_port: $mixed_port
      }],
      outbounds: [
        {type: "selector", tag: "proxy", outbounds: ["safe", "fail-closed"], default: "safe"},
        {type: "direct", tag: "safe"},
        {type: "block", tag: "fail-closed"}
      ],
      route: {final: "proxy"},
      experimental: {
        cache_file: {enabled: $enabled, path: $cache},
        clash_api: {external_controller: $controller, secret: "cache-regression-test"}
      }
    }' >"$destination"
}

start_box() {
  local config="$1"
  "$SING_BOX" check -c "$config"
  "$SING_BOX" run -c "$config" >"$TMP/sing-box.log" 2>&1 &
  BOX_PID=$!
  for _ in {1..50}; do
    if curl -fsS \
      -H 'Authorization: Bearer cache-regression-test' \
      "http://127.0.0.1:$api_port/proxies/proxy" >/dev/null 2>&1; then
      return
    fi
    if ! kill -0 "$BOX_PID" 2>/dev/null; then
      sed -n '1,80p' "$TMP/sing-box.log" >&2
      return 1
    fi
    sleep 0.1
  done
  printf 'FAIL sing-box Clash API did not become ready\n' >&2
  return 1
}

stop_box() {
  kill "$BOX_PID"
  wait "$BOX_PID" 2>/dev/null || true
  BOX_PID=''
}

selection() {
  curl -fsS \
    -H 'Authorization: Bearer cache-regression-test' \
    "http://127.0.0.1:$api_port/proxies/proxy" | jq -r '.now'
}

write_config true "$TMP/cache-enabled.json"
start_box "$TMP/cache-enabled.json"
[[ "$(selection)" == safe ]]
curl -fsS -X PUT \
  -H 'Authorization: Bearer cache-regression-test' \
  -H 'Content-Type: application/json' \
  --data '{"name":"fail-closed"}' \
  "http://127.0.0.1:$api_port/proxies/proxy" >/dev/null
[[ "$(selection)" == fail-closed ]]
stop_box

strings "$TMP/cache.db" | grep -q 'fail-closed'

write_config false "$TMP/cache-disabled.json"
start_box "$TMP/cache-disabled.json"
[[ "$(selection)" == safe ]]
stop_box

printf 'PASS disabled cache ignores a persisted fail-closed selector\n'
