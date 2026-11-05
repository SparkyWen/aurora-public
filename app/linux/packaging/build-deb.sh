#!/usr/bin/env bash
# Package the output of `flutter build linux` as a .deb.
#
#   build-deb.sh <version> <bundle-dir> <out-dir>
#
# <bundle-dir> is build/linux/x64/release/bundle. It must already contain
# sing-box, aurora-svc and aurora-cli (placed there by the install rules in
# linux/CMakeLists.txt). If any is missing this fails outright rather than
# producing a package that installs but cannot connect.
set -euo pipefail

VERSION="${1:?usage: build-deb.sh <version> <bundle-dir> <out-dir>}"
BUNDLE="${2:?}"
OUT="${3:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for required in aurora sing-box aurora-svc aurora-cli; do
  [[ -x "$BUNDLE/$required" ]] || {
    printf 'FAIL missing %s in %s\n' "$required" "$BUNDLE" >&2
    exit 1
  }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/opt/aurora" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/lib/systemd/system" \
         "$STAGE/DEBIAN"

cp -a "$BUNDLE/." "$STAGE/opt/aurora/"
cp "$HERE/aurora.desktop"      "$STAGE/usr/share/applications/aurora.desktop"
cp "$HERE/aurora-svc.service"  "$STAGE/lib/systemd/system/aurora-svc.service"
ln -s /opt/aurora/aurora     "$STAGE/usr/bin/aurora"
# The command line also has its own entry point: `aurora` with arguments execs it
# (see linux/runner/my_application.cc), but on a machine without a display typing
# aurora-cli directly is clearer and does not depend on that exec.
ln -s /opt/aurora/aurora-cli "$STAGE/usr/bin/aurora-cli"

cat >"$STAGE/DEBIAN/control" <<EOF
Package: aurora
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Maintainer: Aurora <noreply@localhost>
Depends: libgtk-3-0 | libgtk-3-0t64, libsecret-1-0, libayatana-appindicator3-1 | libappindicator3-1
Description: Aurora VPN
 Multi-protocol personal VPN with automatic path failover.
EOF

# postinst/prerm only touch systemctl when systemd is the running init. The test
# is the one systemd documents (sd_booted(3)): /run/systemd/system exists iff
# the system was booted with systemd. The target is an Ubuntu desktop, which is
# always systemd, so the normal path always takes this branch -- and a genuine
# problem (unit syntax error, capability denied, ...) must make postinst fail
# and dpkg report an error, not leave a package that looks green but cannot
# connect. The fallback exists only so environments without systemd
# (containers, chroots -- not a target, but used to inspect the package layout)
# are not blocked from installing at all.
cat >"$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable aurora-svc.service
  systemctl restart aurora-svc.service
else
  echo "aurora: systemd is not running (no /run/systemd/system); skipping service registration/start." >&2
  echo "aurora: once systemd is up, run: systemctl enable --now aurora-svc.service" >&2
fi
EOF

cat >"$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

# Stop the service first (its stop path kills sing-box, taking the tunnel down), then remove files.
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now aurora-svc.service || true
fi
EOF

# Only purge removes machine-wide state; remove does not. That is the Debian
# convention: after `apt remove` a reinstall should pick up where it left off,
# and `apt purge` means "as if it had never been here".
#
# What is deleted is the same set `aurora-svc uninstall` deletes on Windows
# (see cleanup.go in aurora-svc): the shared bearer token and the config.json
# the service last ran with -- the latter holds PLAINTEXT credentials. systemd
# does not delete StateDirectory just because the unit is disabled, so without
# this step the credentials would stay on disk.
cat >"$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "purge" ]; then
  rm -rf /var/lib/aurora
fi
EOF

chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"

mkdir -p "$OUT"
dpkg-deb --build --root-owner-group "$STAGE" "$OUT/aurora_${VERSION}_amd64.deb"
printf 'wrote %s/aurora_%s_amd64.deb\n' "$OUT" "$VERSION"
