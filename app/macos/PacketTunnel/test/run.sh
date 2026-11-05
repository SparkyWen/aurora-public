#!/usr/bin/env bash
# Compiles and runs the TunnelProcessHealth policy test.
#
# Needs only the Swift toolchain from the Command Line Tools — no Xcode
# project, no simulator, no signing — because the type under test imports
# nothing but Foundation. That is the whole reason it lives in its own file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
macos_src="$here/../TunnelProcessHealth.swift"
ios_src="$here/../../../ios/PacketTunnel/TunnelProcessHealth.swift"

# The two PacketTunnel targets carry their own copy of every shared source
# (AuroraPlatform.swift already works this way). Copies are only safe while
# they stay identical, so the test refuses to pass on a drifted pair rather
# than silently proving one platform correct and shipping the other broken.
if ! diff -q "$macos_src" "$ios_src" >/dev/null; then
  echo "FAIL: macOS and iOS copies of TunnelProcessHealth.swift have drifted" >&2
  diff "$macos_src" "$ios_src" >&2 || true
  exit 1
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/tunnel_process_health_test" "$macos_src" "$here/main.swift"
"$out/tunnel_process_health_test"

# Exercise provider startup/teardown, not only the health policy.
bash "$here/lifecycle/run.sh"

# Queue ordering and retired monitor callbacks on both Apple platforms.
bash "$here/lifecycle/run-monitor.sh"
