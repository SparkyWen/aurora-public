#!/usr/bin/env bash
# Test the real command-client lifecycle with a deterministic scheduler and a
# libbox transport double; no Flutter framework, signing, or live tunnel needed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
for platform in ios macos; do
  src="$here/../../../$platform/Runner/AuroraVPN.swift"
  sed -n '/^final class AuroraCommandClient:/,/^\/\/ MARK: - error/p' "$src" > "$out/client.swift"
  cat "$here/stubs.swift" "$out/client.swift" "$here/main.swift" > "$out/main.swift"
  swiftc -o "$out/command_client_test" "$out/main.swift"
  echo "Testing $platform command client"
  "$out/command_client_test"
done

for platform in ios macos; do
  src="$here/../../../$platform/Runner/AuroraVPN.swift"
  sed -n '/^\/\/ MARK: - NE disconnect reason/,/^\/\/ MARK: - generic EventChannel/p' "$src" \
    | sed '$d' > "$out/disconnect_reason.swift"
  { printf 'import Foundation\nimport NetworkExtension\n'; cat "$out/disconnect_reason.swift" "$here/disconnect_reason_main.swift"; } > "$out/disconnect_reason_main.swift"
  swiftc -o "$out/disconnect_reason_test" "$out/disconnect_reason_main.swift"
  echo "Testing $platform disconnect reason"
  "$out/disconnect_reason_test"
done

python3 "$here/bundle_permissions_test.py"

bash "$here/keychain/run.sh"
