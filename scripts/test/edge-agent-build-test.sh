#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

[[ -f "$ROOT/edge-agent/Makefile" ]] || fail 'edge-agent Makefile missing'
grep -Fqx '/edge-agent/dist/' "$ROOT/.gitignore" || fail 'edge-agent build output is not ignored'

make -C "$ROOT/edge-agent" test >/dev/null

# The default target builds both agents.
make -C "$ROOT/edge-agent" all DIST="$TMP/default" >/dev/null
[[ -x "$TMP/default/aurora-home-agent" ]] || fail 'make all did not build the home agent'
[[ -x "$TMP/default/aurora-relay-agent" ]] || fail 'make all did not build the relay agent'
file "$TMP/default/aurora-relay-agent" | grep -Fq 'ELF 64-bit LSB executable, x86-64' ||
  fail 'relay agent does not default to Linux amd64'

# Cross-compilation works in every direction a node can need.
make -C "$ROOT/edge-agent" home GOOS=darwin GOARCH=arm64 DIST="$TMP/mac" >/dev/null
# file(1) words this differently per platform: "Mach-O 64-bit executable arm64" on
# macOS, "Mach-O 64-bit arm64 executable" on Linux.
file "$TMP/mac/aurora-home-agent" | grep -Eq 'Mach-O 64-bit.*arm64' ||
  fail 'home agent did not honor GOOS=darwin GOARCH=arm64'
make -C "$ROOT/edge-agent" home GOOS=linux GOARCH=amd64 DIST="$TMP/linux" >/dev/null
file "$TMP/linux/aurora-home-agent" | grep -Fq 'ELF 64-bit LSB executable, x86-64' ||
  fail 'home agent did not honor GOOS=linux GOARCH=amd64'
make -C "$ROOT/edge-agent" relay RELAY_GOARCH=arm64 DIST="$TMP/arm" >/dev/null
file "$TMP/arm/aurora-relay-agent" | grep -Fq 'ELF 64-bit LSB executable, ARM aarch64' ||
  fail 'relay agent did not honor RELAY_GOARCH=arm64'

printf 'PASS edge-agent build targets\n'
