#!/usr/bin/env bash
set -euo pipefail

# sysextd copies the extension as root. Build umask 077 otherwise leaves its
# Info.plist unreadable to normal system clients, even with a valid signature.
bundle="${1:?Usage: $0 /path/to/build/aurora.app}"
while [[ "$bundle" == */ ]]; do bundle="${bundle%/}"; done
if [[ "$bundle" != *.app || ! -d "$bundle" || -L "$bundle" ]]; then
  echo "Expected a real app directory, not a symlink: $bundle" >&2
  exit 1
fi

# find defaults to -P: framework aliases and any outside symlink targets are
# never traversed or chmodded. X preserves executable files without making
# ordinary resources executable. Keep every embedded contract private.
find "$bundle" -type d -exec chmod 0755 {} +
find "$bundle" -type f ! -name aurora-contract.json -exec chmod u=rwX,go=rX {} +
find "$bundle" -type f -name aurora-contract.json -exec chmod 0600 {} +
