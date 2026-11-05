#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root_dir/core"
exec "${GO:-go}" test -count=1 "$root_dir/tests/upstream-dns/selector_https_test.go" "$@"
