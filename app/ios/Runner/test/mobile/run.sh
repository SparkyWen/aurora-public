#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
python3 - "${AURORA_RUNNER_SOURCE:-$here/../../AuroraVPN.swift}" "$out/runner.swift" <<'PYINNER'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
# Exclude imports and the separately tested libbox client. Keep the complete
# production Runner, stream handlers, and local error type unchanged.
runner=source[:source.index('// MARK: - libbox CommandClient')]
runner='\n'.join(line for line in runner.splitlines() if not line.startswith('import '))+'\n'
runner+='\n'+source[source.index('// MARK: - error'):]
Path(sys.argv[2]).write_text('import Foundation\n'+runner)
PYINNER
swiftc -swift-version 5 -parse-as-library "$here/stubs.swift" "$out/runner.swift" "$here/main.swift" -o "$out/test"
"$out/test" "${1:-all}"
