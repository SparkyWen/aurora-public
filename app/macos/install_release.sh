#!/usr/bin/env bash
set -euo pipefail

# Build and install the only runnable Aurora macOS app.
#
# macOS refuses to activate a System Extension from Flutter's raw build path.
# Keeping that .app around also makes Launch Services show two Auroras with the
# same bundle ID. This script installs the signed app in /Applications, archives
# the release as a zip, unregisters the build copy, and removes the raw .app.
#
# Signing and notarization are driven by the environment; nothing here assumes a
# particular Apple account:
#   AURORA_APPLE_TEAM      team id the project is signed with (required for a
#                          signed build; set it in the project with
#                          scripts/set-apple-identity.sh)
#   AURORA_DEVELOPER_ID    optional: substring of the expected signing identity
#                          (e.g. "Developer ID Application: Your Name"); when
#                          set, the built app must be signed by it
#   AURORA_NOTARY_PROFILE  optional: `xcrun notarytool store-credentials`
#                          keychain profile. Without it notarization is skipped
#                          (a dev-signed extension then needs
#                          `systemextensionsctl developer on`)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_APP="$APP_DIR/build/macos/Build/Products/Release/aurora.app"
INSTALL_APP="/Applications/aurora.app"
DIST_DIR="$APP_DIR/build/distribution"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -n "${FLUTTER_BIN:-}" ]]; then
  flutter_bin="$FLUTTER_BIN"
elif command -v flutter >/dev/null 2>&1; then
  flutter_bin="$(command -v flutter)"
elif [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
  flutter_bin="$HOME/development/flutter/bin/flutter"
else
  echo "Flutter not found. Set FLUTTER_BIN=/absolute/path/to/flutter." >&2
  exit 69
fi

skip_build=false
open_after_install=true
for arg in "$@"; do
  case "$arg" in
    --skip-build) skip_build=true ;;
    --no-open) open_after_install=false ;;
    *)
      echo "Usage: $0 [--skip-build] [--no-open]" >&2
      exit 64
      ;;
  esac
done

cd "$APP_DIR"

if [[ -z "${AURORA_APPLE_TEAM:-}" ]]; then
  echo "AURORA_APPLE_TEAM is not set. The PacketTunnel system extension needs a" >&2
  echo "paid Apple Developer team; run scripts/set-apple-identity.sh first, then" >&2
  echo "export AURORA_APPLE_TEAM=<your team id>." >&2
  exit 78
fi
if ! grep -q "DEVELOPMENT_TEAM = $AURORA_APPLE_TEAM;" macos/Runner.xcodeproj/project.pbxproj; then
  echo "macos/Runner.xcodeproj does not use team $AURORA_APPLE_TEAM." >&2
  echo "Run: bash scripts/set-apple-identity.sh --team $AURORA_APPLE_TEAM --bundle-id <your bundle id>" >&2
  exit 78
fi

# A run that stops before the install below (signing, notarization, a refused
# version) must not leave the build copy discoverable either: Xcode registers
# it with Launch Services on every build, and only the success path at the
# bottom unregisters it. Two failed runs (a timestamp-server
# outage, then a notarization 403) once left a second Aurora behind. The bytes
# stay so `--skip-build` can retry them.
unregister_build_copy_on_failure() {
  local status=$?
  if [[ $status -ne 0 && -d "$BUILD_APP" ]]; then
    "$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true
  fi
}
trap unregister_build_copy_on_failure EXIT

if [[ "$skip_build" != true ]]; then
  "$flutter_bin" pub get
  "$flutter_bin" build macos --release \
    --dart-define="AURORA_BUILD_ID=macos-$(date -u +%Y%m%dT%H%M%SZ)"
fi

if [[ ! -d "$BUILD_APP" ]]; then
  echo "Release app not found: $BUILD_APP" >&2
  exit 1
fi

# Normalize the build copy before verification, archiving and notarization.
# Never repair permissions by modifying an already activated host in place.
bash "$SCRIPT_DIR/normalize_bundle_permissions.sh" "$BUILD_APP"
codesign --verify --deep --strict --verbose=2 "$BUILD_APP"
if [[ -n "${AURORA_DEVELOPER_ID:-}" ]]; then
  if ! codesign -dvv "$BUILD_APP" 2>&1 | grep -q "^Authority=.*${AURORA_DEVELOPER_ID}"; then
    echo "The built app is not signed by an identity matching: $AURORA_DEVELOPER_ID" >&2
    exit 1
  fi
fi

host_arch="$(uname -m)"
case "$host_arch" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported release architecture: $host_arch" >&2
    exit 1
    ;;
esac

declare -a native_binaries=(
  "$BUILD_APP/Contents/MacOS/aurora"
  "$BUILD_APP/Contents/Frameworks/App.framework/Versions/A/App"
  "$BUILD_APP/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
  "$BUILD_APP/Contents/Library/SystemExtensions/com.aurora.vpn.PacketTunnel.systemextension/Contents/MacOS/com.aurora.vpn.PacketTunnel"
)
for binary in "${native_binaries[@]}"; do
  if [[ ! -f "$binary" ]]; then
    echo "Required macOS binary is missing: $binary" >&2
    exit 1
  fi
  actual_archs="$(lipo -archs "$binary")"
  if [[ "$actual_archs" != "$host_arch" ]]; then
    echo "Refusing non-native release: $binary has $actual_archs, expected $host_arch" >&2
    exit 1
  fi
done
echo "Native-only macOS architecture verified: $host_arch"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_APP/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILD_APP/Contents/Info.plist")"
extension_plist="$BUILD_APP/Contents/Library/SystemExtensions/com.aurora.vpn.PacketTunnel.systemextension/Contents/Info.plist"
extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension_plist")"
extension_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extension_plist")"
if [[ "$extension_version" != "$version" || "$extension_build" != "$build" ]]; then
  echo "Refusing mismatched release: app $version+$build, PacketTunnel $extension_version+$extension_build" >&2
  exit 1
fi
echo "App and PacketTunnel versions match: $version+$build"
mkdir -p "$DIST_DIR"
archive="$DIST_DIR/Aurora-macOS-${host_arch}-${version}-${build}.zip"
archive_tmp="$archive.tmp"
ditto -c -k --sequesterRsrc --keepParent "$BUILD_APP" "$archive_tmp"
mv -f "$archive_tmp" "$archive"

# Notarize + staple BEFORE installing. sysextd refuses to replace an already
# approved Developer ID system extension when the new app has no notarization
# ticket (OSSystemExtensionErrorDomain code 8 "code signature invalid"), so an
# unnotarized install silently keeps the OLD extension running forever.
# Tip: if a submission sits "In Progress" >10 min, resubmitting the same zip
# usually completes in minutes (tickets are keyed by signature hash).
notary_profile="${AURORA_NOTARY_PROFILE:-}"
if [[ "${AURORA_SKIP_NOTARIZE:-0}" == 1 || -z "$notary_profile" ]]; then
  echo "Skipping notarization (AURORA_NOTARY_PROFILE is not set, or AURORA_SKIP_NOTARIZE=1)."
  echo "A dev-signed system extension will not replace an approved one; for local"
  echo "testing run: systemextensionsctl developer on"
else
  echo "Notarizing $archive (keychain profile: $notary_profile)…"
  # BSD mktemp requires the XXXXXX template at the end of the path. A suffix
  # makes it create one literal file and then fail every subsequent release.
  submit_log="$(mktemp "${TMPDIR:-/tmp}/aurora-notary.XXXXXX")"
  # S3 Transfer Acceleration is repeatedly reset on some VPN and censored paths
  # during multipart uploads. The regular S3 endpoint is slower but release-safe.
  xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" \
    --no-s3-acceleration --wait \
    | tee "$submit_log"
  if ! grep -q "status: Accepted" "$submit_log"; then
    echo "Notarization was not Accepted — aborting install." >&2
    echo "Inspect: xcrun notarytool log <id> --keychain-profile $notary_profile" >&2
    exit 1
  fi
  rm -f "$submit_log"
  xcrun stapler staple "$BUILD_APP"
  # Re-zip so the distributable archive carries the stapled ticket too.
  ditto -c -k --sequesterRsrc --keepParent "$BUILD_APP" "$archive_tmp"
  mv -f "$archive_tmp" "$archive"
fi

# Stop the old UI copies and tunnel before atomically replacing the host app.
scutil --nc stop "Aurora" >/dev/null 2>&1 || true
while IFS= read -r pid; do
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
done < <(pgrep -f '/aurora\.app/Contents/MacOS/aurora$' || true)

install_tmp="/Applications/.aurora.installing.$$.app"
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/aurora-install.XXXXXX")"
ditto "$BUILD_APP" "$install_tmp"
codesign --verify --deep --strict --verbose=2 "$install_tmp"

if [[ -d "$INSTALL_APP" ]]; then
  mv "$INSTALL_APP" "$backup_dir/aurora.app"
fi

if ! mv "$install_tmp" "$INSTALL_APP"; then
  [[ -d "$backup_dir/aurora.app" ]] && mv "$backup_dir/aurora.app" "$INSTALL_APP"
  exit 1
fi

if ! codesign --verify --deep --strict --verbose=2 "$INSTALL_APP"; then
  mv "$INSTALL_APP" "$backup_dir/failed-aurora.app"
  [[ -d "$backup_dir/aurora.app" ]] && mv "$backup_dir/aurora.app" "$INSTALL_APP"
  exit 1
fi
rm -rf "$backup_dir"

# Remove the duplicate Launch Services record. The zip is the distributable;
# the raw build .app must not remain discoverable as a second installed app.
"$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true
rm -rf "$BUILD_APP"
"$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true

# The build copy is not the only duplicate. ditto registers the staging copy
# too, and the record for
# /Applications/.aurora.installing.<pid>.app can outlive the rename: the same
# version, listed twice. Keep exactly /Applications/aurora.app, plus iPhone
# Mirroring's placeholders, which belong to the system.
registered_copies() {
  "$LSREGISTER" -dump 2>/dev/null | awk '
    /^path:/ { sub(/^path:[[:space:]]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); p = $0 }
    /^identifier:/ { if ($2 == "com.aurora.vpn") print p }' | sort -u
}
while IFS= read -r copy; do
  [[ -z "$copy" || "$copy" == "$INSTALL_APP" || "$copy" == */Placeholders-v6.noindex/* ]] && continue
  "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true
  echo "Unregistered duplicate: $copy"
done < <(registered_copies)
"$LSREGISTER" -gc >/dev/null 2>&1 || true
echo "Registered com.aurora.vpn copies:"
registered_copies | sed 's/^/  /'

echo "Installed: $INSTALL_APP"
echo "Archive:   $archive"
du -sh "$INSTALL_APP" "$archive"

if [[ "$open_after_install" == true ]]; then
  open "$INSTALL_APP"
fi
