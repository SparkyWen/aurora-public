#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
python3 - "$repo/app/ios/PacketTunnel/PacketTunnelProvider.swift" "$out/provider.swift" "$repo/app/ios/PacketTunnel/AuroraPlatform.swift" "$out/stop-callback.swift" <<'PYINNER'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text().replace('import Libbox\n','').replace('import NetworkExtension\n','').replace('FileManager.default','TestFileManager.default')
Path(sys.argv[2]).write_text(s)
platform=Path(sys.argv[3]).read_text()
callbacks=[]
for signature in ['    func serviceStop() throws {', '    func clearDNSCache() {']:
    start=platform.index(signature)
    end=start
    level=0
    opened=False
    while end < len(platform):
        if platform[end]=='{': level+=1; opened=True
        elif platform[end]=='}':
            level-=1
            if opened and level==0:
                end+=1; break
        end+=1
    callbacks.append(platform[start:end])
Path(sys.argv[4]).write_text('import Foundation\nextension AuroraPlatform {\n'+'\n'.join(callbacks)+'\n}\n')
PYINNER
swiftc -swift-version 5 -parse-as-library -o "$out/test" \
 "$repo/app/macos/PacketTunnel/test/lifecycle/provider-stubs.swift" "$out/provider.swift" \
 "$repo/app/ios/PacketTunnel/TunnelProcessHealth.swift" "$repo/app/ios/Shared/AuroraTailnetStore.swift" "$repo/app/ios/Shared/AuroraTailnetStoreFiles.swift" "$repo/app/ios/Shared/AuroraTailnetConfig.swift" "$repo/app/ios/Shared/AuroraTailnetAuth.swift" "$here/main.swift" "$out/stop-callback.swift"
status=0
cases=(healthy stale failure stop-during-reload stop-during-create duplicate-reload session-config timeout stale-service-stop stale-dns-clear)
if (( $# > 0 )); then cases=("$@"); fi
for scenario in "${cases[@]}"; do
 mkdir -p "$out/$scenario"
 AURORA_TEST_DIR="$out/$scenario" "$out/test" "$scenario" || status=1
done
exit "$status"
