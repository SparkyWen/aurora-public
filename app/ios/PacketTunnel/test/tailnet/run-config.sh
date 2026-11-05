#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -parse-as-library -o "$out/test" "$ios/Shared/AuroraTailnetStore.swift" "$ios/Shared/AuroraTailnetStoreFiles.swift" "$ios/Shared/AuroraTailnetConfig.swift" "$here/ConfigFixture.swift" "$here/ConfigTests.swift"
"$out/test"
