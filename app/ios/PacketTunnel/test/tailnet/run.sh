#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
chmod 700 "$out"
sources=("$ios/Shared/AuroraTailnetStore.swift")
if [[ -f "$ios/Shared/AuroraTailnetStoreFiles.swift" ]]; then sources+=("$ios/Shared/AuroraTailnetStoreFiles.swift"); fi
swiftc -swift-version 5 -parse-as-library -o "$out/test" "${sources[@]}" "$here/StoreTests.swift"
mkdir "$out/data"
chmod 700 "$out/data"
AURORA_TAILNET_TEST_ROOT="$out/data" "$out/test"
