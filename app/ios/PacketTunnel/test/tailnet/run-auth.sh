#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/../../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -parse-as-library -o "$out/test" "$ios/Shared/AuroraTailnetAuth.swift" "$here/AuthTests.swift"
"$out/test"
