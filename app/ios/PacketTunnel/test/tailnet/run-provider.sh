#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../../.." && pwd)"
ios="$repo/app/ios"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
python3 - "$ios/PacketTunnel/PacketTunnelProvider.swift" "$out/provider.swift" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text().replace('import Libbox\n','').replace('import NetworkExtension\n','').replace('FileManager.default','TestFileManager.default')
Path(sys.argv[2]).write_text(s)
PY
swiftc -swift-version 5 -parse-as-library -o "$out/test" "$repo/app/macos/PacketTunnel/test/lifecycle/provider-stubs.swift" "$out/provider.swift" "$ios/PacketTunnel/TunnelProcessHealth.swift" "$ios/Shared/AuroraTailnetStore.swift" "$ios/Shared/AuroraTailnetStoreFiles.swift" "$ios/Shared/AuroraTailnetConfig.swift" "$ios/Shared/AuroraTailnetAuth.swift" "$here/ConfigFixture.swift" "$here/ProviderTests.swift"
status=0
cases=(setup-error-safe allocation-error-safe reload-fresh-owner reload-close-error reload-stop-during-create lease-held clean-close close-throws-retains-lease stale-generation wrong-digest wrong-node boolean-generation extra-options ordinary-start-with-tailnet)
if (( $# > 0 )); then cases=("$@"); fi
for scenario in "${cases[@]}"; do
 mkdir -p "$out/$scenario"
 AURORA_TEST_DIR="$out/$scenario" "$out/test" "$scenario" || status=1
done
exit "$status"
