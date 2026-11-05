#!/usr/bin/env bash
# Self-test for scripts/set-apple-identity.sh. Non-destructive: it copies the
# relevant parts of the repository into a temp directory and points the script at
# the copy with AURORA_REPO_ROOT.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/scripts/set-apple-identity.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aurora-identity-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

TEAM="ABCDE12345"
BUNDLE="com.example.myaurora"
failures=0
ok()   { echo "ok:   $1"; }
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
check() { # <description> <command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi
}

copy="$WORK/repo"
mkdir -p "$copy"
(cd "$REPO" && tar -cf - --exclude=Pods --exclude=build --exclude='*.xcframework' \
  --exclude=ephemeral --exclude=.symlinks app/ios app/macos) | (cd "$copy" && tar -xf -)

# --- argument validation -------------------------------------------------
run() { AURORA_REPO_ROOT="$copy" bash "$SCRIPT" "$@"; }
check "rejects a missing team"       bash -c '! AURORA_REPO_ROOT="$0" bash "$1" --bundle-id com.a.b' "$copy" "$SCRIPT"
check "rejects a missing bundle id"  bash -c '! AURORA_REPO_ROOT="$0" bash "$1" --team ABCDE12345' "$copy" "$SCRIPT"
check "rejects a malformed team"     bash -c '! AURORA_REPO_ROOT="$0" bash "$1" --team abc --bundle-id com.a.b' "$copy" "$SCRIPT"
check "rejects a malformed bundle id" bash -c '! AURORA_REPO_ROOT="$0" bash "$1" --team ABCDE12345 --bundle-id nodots' "$copy" "$SCRIPT"
check "rejects an unknown flag"      bash -c '! AURORA_REPO_ROOT="$0" bash "$1" --bogus' "$copy" "$SCRIPT"

# --- the rewrite ---------------------------------------------------------
run --team "$TEAM" --bundle-id "$BUNDLE" >"$WORK/first.out"

count() { grep -rIFl --exclude-dir=Pods -e "$1" "$copy/app" 2>/dev/null | wc -l | tr -d ' '; }
[[ "$(count 'com.aurora.vpn')" == 0 ]] && ok "no com.aurora.vpn left" \
  || { fail "com.aurora.vpn still present"; grep -rIF "com.aurora.vpn" "$copy/app" | head -5 >&2; }
[[ "$(count "group.$BUNDLE")" -gt 0 ]] && ok "app group rewritten to group.$BUNDLE" \
  || fail "group.$BUNDLE not found"
[[ "$(count "$BUNDLE.PacketTunnel")" -gt 0 ]] && ok "extension id rewritten" \
  || fail "$BUNDLE.PacketTunnel not found"
# The group prefix must not be doubled, and the id must not be mangled.
if grep -rIF "group.group." "$copy/app" >/dev/null 2>&1; then fail "doubled group prefix"; else ok "no doubled group prefix"; fi

for pbx in "$copy/app/ios/Runner.xcodeproj/project.pbxproj" \
           "$copy/app/macos/Runner.xcodeproj/project.pbxproj"; do
  name="${pbx#"$copy"/}"
  if grep -q 'DEVELOPMENT_TEAM = ' "$pbx" \
     && ! grep 'DEVELOPMENT_TEAM = ' "$pbx" | grep -vq "DEVELOPMENT_TEAM = $TEAM;"; then
    ok "$name: every DEVELOPMENT_TEAM is $TEAM"
  else
    fail "$name: DEVELOPMENT_TEAM not uniformly $TEAM"
  fi
done

# --- idempotence ---------------------------------------------------------
snapshot() { (cd "$copy" && find app -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum | cksum); }
before="$(snapshot)"
run --team "$TEAM" --bundle-id "$BUNDLE" >"$WORK/second.out"
after="$(snapshot)"
[[ "$before" == "$after" ]] && ok "second run changes nothing" || fail "second run changed files"
grep -q "Nothing to change" "$WORK/second.out" && ok "second run reports nothing to change" \
  || fail "second run did not report 'Nothing to change'"

# --- re-targeting to a different id works too ------------------------------
run --team "ZZZZZ99999" --bundle-id "org.example.other" >/dev/null
[[ "$(count "$BUNDLE")" == 0 ]] && ok "re-run with another id replaces the previous one" \
  || fail "previous id still present after re-run"

# --- the source tree itself was not touched --------------------------------
if grep -rIF "$BUNDLE" "$REPO/app/ios" "$REPO/app/macos" >/dev/null 2>&1; then
  fail "the real repository was modified"
else
  ok "the real repository was not modified"
fi

echo
if [[ $failures -eq 0 ]]; then echo "PASS"; else echo "$failures FAILED" >&2; exit 1; fi
