#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -warnings-as-errors "$here/../../AuroraKeychainMigration.swift" "$here/../../AuroraKeychainDefaultACL.swift" "$here/main.swift" -o "$out/keychain-test"
"$out/keychain-test"
swiftc -parse-as-library -warnings-as-errors "$here/../../AuroraKeychainMigration.swift" "$here/../../AuroraKeychainDefaultACL.swift" \
  "$here/../../AuroraKeychainMaintenance.swift" "$here/maintenance.swift" -o "$out/maintenance-test"
"$out/maintenance-test"
swiftc -parse-as-library -warnings-as-errors "$here/../../AuroraKeychainMigration.swift" "$here/../../AuroraKeychainDefaultACL.swift" \
  "$here/../../AuroraKeychainMaintenance.swift" "$here/check.swift" -o "$out/check-test"
"$out/check-test"
# Compile the complete production entry and window with actual Apple SDKs;
# substitute only the unavailable Flutter/libbox boundary. Invalid maintenance
# requests must exit before opening a GUI, reading VPN preferences or Keychain.
swiftc -emit-library -emit-module -module-name FlutterMacOS \
  "$here/FlutterMacOS.swift" -o "$out/libFlutterMacOS.dylib" -emit-module-path "$out/FlutterMacOS.swiftmodule"
swiftc -parse-as-library -warnings-as-errors -I "$out" -L "$out" -lFlutterMacOS \
  -Xlinker -rpath -Xlinker "$out" "$here/../../AppDelegate.swift" \
  "$here/../../MainFlutterWindow.swift" "$here/../../AuroraKeychainMigration.swift" "$here/../../AuroraKeychainDefaultACL.swift" \
  "$here/../../AuroraKeychainMaintenance.swift" "$here/entry-stubs.swift" -o "$out/entry-test"
python3 - "$out/entry-test" <<'PY'
import subprocess, sys
for args in [
    ['--rollback-keychain-accessibility'],
    ['--rollback-keychain-accessibility', '--confirm-aurora-stopped', '--start-vpn'],
    ['--rollback-keychain-accessibility=unexpected'],
]:
    result = subprocess.run([sys.argv[1], *args], capture_output=True, timeout=10)
    assert result.returncode == 1, result.returncode
    assert result.stdout == b'' and result.stderr == b'KEYCHAIN_ROLLBACK_REFUSED\n'
print('PASS actual AppDelegate: 3 invalid maintenance requests exit before Flutter/VPN/Keychain')
PY
# Retain the production policy and entry; replace only the Security adapter so
# valid CLI tests never query the test runner's real Aurora Keychain namespace.
python3 - "$here/../../AuroraKeychainMigration.swift" "$out/migration-entry.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
marker = 'final class AuroraSystemKeychainAPI: AuroraKeychainAPI {'
assert source.count(marker) == 1
Path(sys.argv[2]).write_text(source.split(marker)[0])
PY
swiftc -parse-as-library -warnings-as-errors -I "$out" -L "$out" -lFlutterMacOS \
  -Xlinker -rpath -Xlinker "$out" "$here/../../AppDelegate.swift" \
  "$here/../../MainFlutterWindow.swift" "$out/migration-entry.swift" "$here/../../AuroraKeychainDefaultACL.swift" \
  "$here/../../AuroraKeychainMaintenance.swift" "$here/entry-check-api.swift" \
  "$here/entry-stubs.swift" -o "$out/check-entry-test"
python3 - "$out/check-entry-test" <<'PY'
import os, subprocess, sys
option = '--check-keychain-accessibility'
cases = [
    ([option], 'legacy', 0, b'KEYCHAIN_ACCESSIBILITY_COMPATIBLE legacy=7 background=0 absent=0\n'),
    ([option], 'locked', 2, b'KEYCHAIN_ACCESSIBILITY_LOCKED\n'),
    ([option], 'refused', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=security status=-34018\n'),
    ([option], 'result-type', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=result-type\n'),
    ([option], 'duplicate', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=multiple-matches\n'),
    ([option], 'unknown-schema', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=unknown-attributes schema=generic,unrecognized-present\n'),
    ([option + '=extra'], 'no-query', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=arguments\n'),
    ([option, '--start-vpn'], 'no-query', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=arguments\n'),
    ([option, option], 'no-query', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=arguments\n'),
    (['--rollback-keychain-accessibility', option], 'no-query', 3, b'KEYCHAIN_ACCESSIBILITY_REFUSED reason=arguments\n'),
]
failed = 0
for args, mode, code, output in cases:
    result = subprocess.run([sys.argv[1], *args], capture_output=True, timeout=10,
        env={**os.environ, 'AURORA_KEYCHAIN_ENTRY_FIXTURE': mode})
    okay = result.returncode == code and (
        (result.stdout == output and result.stderr == b'') if code == 0
        else (result.stderr == output and result.stdout == b''))
    failed += not okay
    print(f'{"PASS" if okay else "FAIL"} actual read-only AppDelegate: {mode}, exit={result.returncode}')
print(f'Read-only AppDelegate: {len(cases) - failed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY

swiftc -parse-as-library -warnings-as-errors "$here/../../AuroraKeychainMigration.swift" \
  "$here/../../AuroraKeychainDefaultACL.swift" "$here/default-acl.swift" -o "$out/default-acl-test"
"$out/default-acl-test"
swiftc -parse-as-library -warnings-as-errors "$here/../../AuroraKeychainMigration.swift" \
  "$here/../../AuroraKeychainDefaultACL.swift" "$here/../../AuroraKeychainMaintenance.swift" \
  "$here/qualify.swift" -o "$out/qualify-test"
"$out/qualify-test"

python3 - "$here/../../AuroraKeychainDefaultACL.swift" "$out/defaults-entry.swift" <<'PY2'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
marker = 'final class AuroraSystemDefaultACLAPI: AuroraKeychainDefaultACLAPI {'
assert source.count(marker) == 1
Path(sys.argv[2]).write_text(source.split(marker)[0])
PY2
swiftc -parse-as-library -warnings-as-errors -I "$out" -L "$out" -lFlutterMacOS \
  -Xlinker -rpath -Xlinker "$out" "$here/../../AppDelegate.swift" \
  "$here/../../MainFlutterWindow.swift" "$out/migration-entry.swift" "$out/defaults-entry.swift" \
  "$here/../../AuroraKeychainMaintenance.swift" "$here/entry-qualify-api.swift" \
  "$here/entry-stubs.swift" -o "$out/qualify-entry-test"
python3 - "$out/qualify-entry-test" <<'PY2'
import os, subprocess, sys
option = '--qualify-keychain-default-acl'
cases = [
    ([option], 'okay', 0, b'KEYCHAIN_DEFAULT_ACL_QUALIFIED legacy=7 background=0 absent=0 dummy-roundtrip=passed cleanup=confirmed\n'),
    ([option], 'cleanup', 3, b'KEYCHAIN_DEFAULT_ACL_REFUSED reason=fixture-cleanup\n'),
    ([option + '=extra'], 'no-query', 3, b'KEYCHAIN_DEFAULT_ACL_REFUSED reason=arguments\n'),
    ([option, '--start-vpn'], 'no-query', 3, b'KEYCHAIN_DEFAULT_ACL_REFUSED reason=arguments\n'),
    ([option, option], 'no-query', 3, b'KEYCHAIN_DEFAULT_ACL_REFUSED reason=arguments\n'),
]
failed = 0
for args, mode, code, output in cases:
    result = subprocess.run([sys.argv[1], *args], capture_output=True, timeout=10,
        env={**os.environ, 'AURORA_KEYCHAIN_ENTRY_FIXTURE': mode})
    okay = result.returncode == code and (
        (result.stdout == output and result.stderr == b'') if code == 0
        else (result.stderr == output and result.stdout == b''))
    failed += not okay
    print(f'{"PASS" if okay else "FAIL"} actual qualification AppDelegate: {mode}, exit={result.returncode}')
print(f'Qualification AppDelegate: {len(cases) - failed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY2
