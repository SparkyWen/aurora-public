# Building from source

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.44 or newer (Dart 3.12+). Public builds embed no servers:
users add them after installing.

```bash
cd app
flutter pub get
flutter analyze
flutter test
```

The CI workflows in [`.github/workflows/`](../.github/workflows) are the authoritative recipes. If something here disagrees
with them, they win.

A private fork can ship with a server built in by placing a contract at `app/assets/configs/aurora-contract.json`. That path is
gitignored because it holds real credentials. Never publish a build made this way: anyone can extract the keys from it.

## Mobile core (Android and Apple)

Android, iOS and macOS link sing-box through `libbox`, built with **sagernet's gomobile fork**, not upstream `x/mobile`, which
cannot use NDK r26+.

```bash
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
gomobile init
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12   # after init, which installs gobind@latest

cd core
make android   # -> app/android/app/libs/libbox.aar             (needs ANDROID_NDK_HOME, NDK r28)
make ios       # -> app/ios/PacketTunnel/Libbox.xcframework     (macOS only)
```

`core/go.mod` pins sing-box and `sing-tun` deliberately. See the comments in [`core/Makefile`](../core/Makefile) before changing
them.

## Android

```bash
cd core && make android ABIS=android/arm64 && cd ..
cd app
flutter build apk --release --target-platform android-arm64
```

To sign, create `app/android/key.properties` (gitignored) with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`. Without
it the build falls back to debug signing, which installs fine but cannot upgrade over a differently signed build. Keep your
keystore safe: losing it means users must uninstall to upgrade.

## iOS

Apple only grants the `packet-tunnel-provider` entitlement to **paid** developer accounts, so a free account cannot build this,
and every builder needs their own bundle identifier.

```bash
bash scripts/set-apple-identity.sh --team ABCDE12345 --bundle-id com.you.aurora
cd core && make ios && cd ..
cd app
flutter build ios --release
flutter install --release -d <device-id>
```

Use release builds for daily use. Debug builds are JIT and die when unplugged from the Mac. Do the identity change on a branch you
will not push upstream.

## macOS

The tunnel runs as a system extension, which macOS only activates from `/Applications` with a properly signed app.

```bash
bash scripts/set-apple-identity.sh --team ABCDE12345 --bundle-id com.you.aurora
AURORA_APPLE_TEAM=ABCDE12345 \
AURORA_DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)" \
AURORA_NOTARY_PROFILE=your-notarytool-profile \
  bash app/macos/install_release.sh
```

See [`app/macos/README.md`](../app/macos/README.md). The app and extension versions must match, or the script refuses to install:
a system extension is only replaced when its version changes.

## Windows

Windows does not use libbox. The app hands a compiled config to `aurora-svc`, a Go service running as LocalSystem, which runs the
official `sing-box.exe` and `wintun.dll`.

```powershell
# Place these three in app/windows/aurora-svc/ (see the README there for download links):
#   sing-box.exe, wintun.dll, aurora-svc.exe
cd desktop/aurora-svc
go build -o ..\..\app\windows\aurora-svc\aurora-svc.exe .\...

cd ..\..\app
flutter build windows --release
# Package with Inno Setup: app/windows/installer/aurora.iss
```

See [`app/windows/README.md`](../app/windows/README.md).

## Linux

Same shape as Windows, with a systemd service.

```bash
sudo apt-get install ninja-build libgtk-3-dev libsecret-1-dev libayatana-appindicator3-dev

# Place sing-box, aurora-svc and aurora-cli in app/linux/aurora-svc/ (see the README there):
(cd desktop/aurora-svc && go build -o ../../app/linux/aurora-svc/aurora-svc ./...)
cd app
dart build cli -o build/cli
install -m 0755 build/cli/bundle/bin/aurora_cli linux/aurora-svc/aurora-cli
flutter build linux --release
bash linux/packaging/build-deb.sh
```

## Other components

| Component | Build | Test |
| --- | --- | --- |
| `desktop/aurora-svc` | `go build ./...` | `go test ./...` |
| `edge-agent` | `make` | `go test ./...` |
| `control-plane` | `npx wrangler deploy` | `node --test` |
| `install.sh` | none | `SING_BOX=... bash deploy/test/installer-test.sh` |

## Pinned versions

| Thing | Version | Where |
| --- | --- | --- |
| sing-box (mobile) | 1.13.14 | `core/go.mod` |
| sing-box (node, with checksums) | 1.13.14 | `install.sh` |
| sing-box (desktop) | 1.13.14 | `.github/workflows/release.yml` |
| Wintun | 0.14.1 | `.github/workflows/release.yml` |

Keep them in step. Updating the node's version means updating the checksums in `install.sh` too. Compute them from the official
release archives, and let CI prove the new version with a real install.
