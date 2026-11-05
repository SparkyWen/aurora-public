# Aurora app (Flutter)

The Aurora client: a multi-protocol VPN app that picks a working route
automatically. `lib/` holds the shared Dart logic; each platform has a native
layer (`android/`, `ios/` with the `PacketTunnel` network extension, `macos/`
with a system extension, `windows/`, `linux/`). The full build instructions are
in [`docs/building.md`](../docs/building.md); this file is the short version.

## No contract ships with the app

Public builds embed no contract. On first launch the app is empty and you add a
server by pasting or scanning an `aurora://` link printed by `install.sh`. A
private fork may bake a contract into the build by placing it at
`app/assets/configs/aurora-contract.json` (that file is gitignored; never commit
it).

## Build

```bash
cd app
flutter pub get
flutter test
flutter analyze
flutter build apk --release        # Android
```

The sing-box core is not built by Flutter. Build the mobile libraries first with
`make android` or `make ios` in `core/`, and place the desktop components as
described in `windows/README.md`, `linux/aurora-svc/README.md` and
`macos/README.md`.

## Apple platforms: use your own identity

Apple bundle ids are globally unique per developer account, and the
`packet-tunnel-provider` network extension entitlement cannot be signed by a free
personal team: you need a paid Apple Developer Program team. The repository
therefore ships with a placeholder identity (`com.aurora.vpn`, empty
`DEVELOPMENT_TEAM`). Rewrite it for your account on a branch you will not push
upstream:

```bash
bash scripts/set-apple-identity.sh --team ABCDE12345 --bundle-id com.you.aurora
```

This updates the bundle id and App Group (`group.<bundle id>`) everywhere under
`ios/` and `macos/`, and sets `DEVELOPMENT_TEAM` in both Xcode projects. You must
also sign in to the same team in Xcode (Settings > Accounts) so automatic signing
can create provisioning profiles that include the network extension.

The Ruby helpers that wire the extension targets read the same values from the
environment: `AURORA_APPLE_TEAM` and `AURORA_BUNDLE_ID`.

## Installing on an iOS device

Install a **release** build for daily use. A debug build of a Flutter iOS app is
JIT-compiled and needs the debug service on your Mac, so it white-screens or
exits as soon as the cable is unplugged. A release build is a self-contained AOT
build that runs standalone after one install over USB.

```bash
# First install over USB (the app then works offline).
flutter run --release -d <device-id> --device-connection=attached

# Install only, without a debug session:
flutter install --release -d <device-id>

# Development with hot reload (must stay connected):
flutter run --debug -d <device-id>
```

List device ids with `flutter devices`. The device needs Developer Mode enabled
(Settings > Privacy & Security > Developer Mode).

## Checking that it works

In the app, tap Connect, accept the system "Add VPN Configuration" prompt (the
first time only), and wait for the status to read Connected. Then open
`https://ifconfig.me` in a browser: the address it shows should be the exit
address of the node you connected through.
