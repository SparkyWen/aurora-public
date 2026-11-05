#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
status=0
for platform in macos ios; do
  python3 - "$repo/app/$platform/PacketTunnel/PacketTunnelProvider.swift" "$out/provider.swift" "$out" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
source = source.replace('import Libbox\n', '').replace('import NetworkExtension\n', '')
source = source.replace('FileManager.default', 'TestFileManager.default')
# Redirect only diagnostic locations; never touch a running local extension's logs.
source = source.replace('/tmp/aurora-core.log', sys.argv[3] + '/core.log')
source = source.replace('/tmp/aurora-ext.log', sys.argv[3] + '/ext.log')
Path(sys.argv[2]).write_text(source)
PY
  definitions=(-D AURORA_TEST_IOS)
  if [[ "$platform" == macos ]]; then definitions=(-D AURORA_TEST_MACOS); fi
  dependencies=("$here/provider-stubs.swift")
  if [[ "$platform" == ios ]]; then dependencies+=("$repo/app/ios/Shared/AuroraTailnetStore.swift" "$repo/app/ios/Shared/AuroraTailnetStoreFiles.swift" "$repo/app/ios/Shared/AuroraTailnetConfig.swift" "$repo/app/ios/Shared/AuroraTailnetAuth.swift"); fi
  swiftc "${definitions[@]}" -swift-version 5 -parse-as-library -o "$out/provider-test" \
    "${dependencies[@]}" "$out/provider.swift" \
    "$repo/app/$platform/PacketTunnel/TunnelProcessHealth.swift" "$here/provider-main.swift"
  cases=(healthy listener-failure core-failure close-throws)
  if [[ "$platform" == macos ]]; then cases+=(stale-close-timeout stop-service-throws); fi
  for scenario in "${cases[@]}"; do
    mkdir -p "$out/$platform-$scenario"
    echo "Testing $platform $scenario"
    AURORA_TEST_DIR="$out/$platform-$scenario" "$out/provider-test" "$scenario" || status=1
  done
done
exit "$status"
