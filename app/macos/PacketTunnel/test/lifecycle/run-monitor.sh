#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
status=0
for platform in macos ios; do
  python3 - "$repo/app/$platform/PacketTunnel/AuroraPlatform.swift" "$out/platform.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
# Include the actual stored state/reset plus actual start/close/notify/timer
# bodies. Only unrelated TUN/DNS/owner/platform protocol methods are omitted.
head = source[source.index('final class AuroraPlatform:'):source.index('// MARK: - LibboxPlatformInterface')]
monitor = source[source.index('    func startDefaultInterfaceMonitor('):source.index('    func getInterfaces(')]
Path(sys.argv[2]).write_text('import Foundation\n' + head + '\nextension AuroraPlatform {\n' + monitor + '}\n')
PY
  cp "$here/monitor-main.swift" "$out/main.swift"
  swiftc -swift-version 5 -o "$out/monitor-test" "$here/monitor-stubs.swift" "$out/platform.swift" "$out/main.swift"
  for scenario in normal-close reset-before-replacement late-close late-callback close-before-first-path proxy-rewrapped-close proxy-late-close; do
    echo "Testing $platform $scenario"
    "$out/monitor-test" "$scenario" || status=1
  done
done
exit "$status"
