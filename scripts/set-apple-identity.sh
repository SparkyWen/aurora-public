#!/usr/bin/env bash
# Point the iOS and macOS projects at YOUR Apple developer identity.
#
#   bash scripts/set-apple-identity.sh --team ABCDE12345 --bundle-id com.you.aurora
#
# Why this is needed
#   Apple bundle ids are globally unique per developer account, so the placeholder
#   id this repository ships with (com.aurora.vpn) cannot be signed by anyone else.
#   The packet-tunnel-provider / system-extension entitlements the VPN needs also
#   cannot be signed by a free personal team: you need a paid Apple Developer
#   Program team. This script rewrites the repository to use your team and your
#   bundle id so Xcode can create provisioning profiles for them.
#
# What it changes (in place, under app/ios and app/macos only)
#   * the bundle id and the App Group everywhere they occur: com.aurora.vpn
#     becomes <bundle-id>, group.com.aurora.vpn becomes group.<bundle-id> (Swift
#     sources, entitlements, plists, xcconfig, pbxproj, Ruby helpers, shell
#     scripts and READMEs);
#   * DEVELOPMENT_TEAM in both Runner.xcodeproj/project.pbxproj files.
#
# It is idempotent (running it again with the same values changes nothing) and it
# works with BSD and GNU userland (it uses perl, never sed -i).
#
# IMPORTANT: this rewrites tracked files with identifiers that belong to you. Run
# it on a branch you will NOT push upstream, and do not commit the result to a
# shared repository.
#
# Options
#   --team <id>         10-character Apple team id (required)
#   --bundle-id <id>    reverse-DNS bundle id for the app (required)
#   --from <id>         the id to replace; by default it is detected from the
#                       sources, falling back to com.aurora.vpn
#   -h, --help          show this help
#
# Environment
#   AURORA_REPO_ROOT    repository root to operate on (default: the parent of the
#                       directory containing this script); used by the self-test

set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 64; }

TEAM=""
BUNDLE_ID=""
FROM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) [[ $# -ge 2 ]] || die "--team needs a value"; TEAM="$2"; shift 2 ;;
    --bundle-id) [[ $# -ge 2 ]] || die "--bundle-id needs a value"; BUNDLE_ID="$2"; shift 2 ;;
    --from) [[ $# -ge 2 ]] || die "--from needs a value"; FROM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$TEAM" ]] || die "--team is required (see --help)"
[[ -n "$BUNDLE_ID" ]] || die "--bundle-id is required (see --help)"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] \
  || die "--team must be a 10-character team id of capital letters and digits, got: $TEAM"
bundle_re='^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$'
[[ "$BUNDLE_ID" =~ $bundle_re ]] \
  || die "--bundle-id must look like com.example.aurora (reverse-DNS, at least two parts), got: $BUNDLE_ID"
[[ "$BUNDLE_ID" != *.PacketTunnel ]] \
  || die "--bundle-id is the app's id; the .PacketTunnel suffix is added for you"
if [[ -n "$FROM" ]]; then
  [[ "$FROM" =~ $bundle_re ]] || die "--from is not a valid bundle id: $FROM"
fi
command -v perl >/dev/null 2>&1 || die "perl is required"

ROOT="${AURORA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -d "$ROOT/app/ios" && -d "$ROOT/app/macos" ]] \
  || die "$ROOT does not look like the Aurora repository (no app/ios or app/macos)"

# Work out which id is currently in the sources, so the script can also be re-run
# with a different bundle id later.
if [[ -z "$FROM" ]]; then
  FROM="com.aurora.vpn"
  detected="$(sed -n 's/.*providerBundleID = "\(.*\)\.PacketTunnel".*/\1/p' \
    "$ROOT/app/macos/Runner/AuroraVPN.swift" 2>/dev/null | head -n 1)"
  [[ -n "$detected" ]] && FROM="$detected"
fi

PBX_FILES=(
  "$ROOT/app/ios/Runner.xcodeproj/project.pbxproj"
  "$ROOT/app/macos/Runner.xcodeproj/project.pbxproj"
)
for f in "${PBX_FILES[@]}"; do
  [[ -f "$f" ]] || die "missing $f"
done

# Rewrites one file; prints "<n> <path>" when it changed. Only touches the file
# when something matched, so unrelated files keep their mtime.
rewrite() {
  FROM_ID="$FROM" TO_ID="$BUNDLE_ID" TEAM_ID="$TEAM" IS_PBX="$2" \
  perl -e '
    my $path = shift;
    open(my $in, "<:raw", $path) or die "$path: $!";
    local $/; my $s = <$in>; close $in;
    my ($from, $to, $team) = @ENV{qw(FROM_ID TO_ID TEAM_ID)};
    my $n;
    # Bundle ids and app groups: the "group." prefix stays outside the match, so
    # group.<from> becomes group.<to>. Not preceded by an id character, and not
    # followed by one (com.aurora.vpn must not match com.aurora.vpnx).
    my $orig = $s;
    $s =~ s/(?<![A-Za-z0-9-])\Q$from\E(?![A-Za-z0-9-])/$to/g if $from ne $to;
    if ($ENV{IS_PBX} eq "1") {
      $s =~ s/(DEVELOPMENT_TEAM = )(?:"[^"]*"|[A-Za-z0-9]*);/$1$team;/g;
    }
    $n = ($s ne $orig) ? 1 : 0;
    if ($n) {
      open(my $out, ">:raw", $path) or die "$path: $!";
      print $out $s; close $out;
      print "$n\n";
    }
  ' "$1"
}

changed=0
report() { # <count> <path>
  changed=$((changed + 1))
  printf '  updated %s\n' "${2#"$ROOT"/}"
}

echo "Repository: $ROOT"
echo "Bundle id:  $FROM -> $BUNDLE_ID   (App Group: group.$BUNDLE_ID)"
echo "Team:       $TEAM"
echo

# Candidate text files: everything under app/ios and app/macos that mentions the
# id, except dependencies, build output and prebuilt frameworks. grep -I skips
# binary files.
candidates="$(
  { grep -rIlF --exclude-dir=Pods --exclude-dir=build --exclude-dir=ephemeral \
      --exclude-dir=.symlinks --exclude-dir='*.xcframework' --exclude-dir='*.framework' \
      -e "$FROM" "$ROOT/app/ios" "$ROOT/app/macos" 2>/dev/null || true; } | LC_ALL=C sort
)"

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  is_pbx=0
  case "$file" in */Runner.xcodeproj/project.pbxproj) is_pbx=1 ;; esac
  out="$(rewrite "$file" "$is_pbx")"
  [[ -n "$out" ]] && report "$out" "$file"
done <<<"$candidates"

# The team lives in the pbxproj files even if they no longer mention the old id.
for f in "${PBX_FILES[@]}"; do
  if ! grep -qF "$f" <<<"$candidates"; then
    out="$(rewrite "$f" 1)"
    [[ -n "$out" ]] && report "$out" "$f"
  fi
done

echo
if [[ $changed -eq 0 ]]; then
  echo "Nothing to change: the sources already use $BUNDLE_ID and team $TEAM."
else
  echo "Updated $changed file(s)."
fi
cat <<EOF

Next steps
  * Run this on a branch you will NOT push upstream; these edits are specific to
    your Apple account.
  * Sign in to team $TEAM in Xcode (Settings > Accounts) so automatic signing can
    create profiles that include the network extension.
  * Export AURORA_APPLE_TEAM=$TEAM (and AURORA_BUNDLE_ID=$BUNDLE_ID) for the Ruby
    helpers and app/macos/install_release.sh.
EOF
