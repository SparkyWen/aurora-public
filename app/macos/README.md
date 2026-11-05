# Aurora for macOS: build, signing, system extension

## Architecture in one paragraph

The macOS app reuses the iOS NEPacketTunnelProvider + libbox approach. The Runner
uses `AuroraVPN.swift` (an AppKit port of the iOS channel bridge) to drive an
`NETunnelProviderManager`, plus a PacketTunnel extension packaged as a **system
extension** that runs sing-box (libbox). The TUN captures all traffic, and after
the system extension is approved once, no further approvals are needed.

## Sources in this repository

- `core/Makefile`'s `ios` target builds `-target=ios,macos`, so one bind produces
  a `Libbox.xcframework` containing a macOS slice.
- `macos/Runner/AuroraVPN.swift` is the AppKit port of the iOS channel bridge
  (no UIKit; `openVpnSettings` uses a macOS Settings deep link; `prepare()`
  activates the system extension first).
- `macos/Runner/SystemExtensionInstaller.swift` activates or replaces the
  extension through `OSSystemExtensionRequest`.
- `macos/Runner/AppDelegate.swift` registers `AuroraVPN` on the Flutter engine's
  messenger; closing the window does not quit the app.
- `macos/PacketTunnel/{PacketTunnelProvider,AuroraPlatform}.swift`, `Info.plist`
  (system-extension form, `NEProviderClasses`) and `PacketTunnel.entitlements`.
- The Runner's `Release/DebugProfile.entitlements` already carry the App Group
  and system-extension entitlements.

## Setting up your own signing

Signing needs a **paid Apple Developer Program team**, because the
`packet-tunnel-provider` and system-extension entitlements cannot be signed by a
free team. The repository ships with a placeholder bundle id (`com.aurora.vpn`)
and an empty team. Rewrite them for your account (on a branch you will not push):

```bash
bash scripts/set-apple-identity.sh --team ABCDE12345 --bundle-id com.you.aurora
export AURORA_APPLE_TEAM=ABCDE12345
```

The Xcode project already contains the Runner and PacketTunnel targets. If you
ever need to regenerate the PacketTunnel target, `macos/add_packettunnel.rb`
does it (idempotently) and reads `AURORA_APPLE_TEAM` and `AURORA_BUNDLE_ID` from
the environment. The manual equivalent in Xcode is:

1. Build libbox with the macOS slice: `cd core && make ios`
   (output: `app/ios/PacketTunnel/Libbox.xcframework`).
2. Open `app/macos/Runner.xcworkspace`.
3. Add `Runner/AuroraVPN.swift` and `Runner/SystemExtensionInstaller.swift` to
   the Runner target.
4. Create a PacketTunnel target (File > New > Target > Network Extension, macOS),
   delete the template `.swift`, and add `PacketTunnel/{PacketTunnelProvider,
   AuroraPlatform}.swift`, `Info.plist` and `PacketTunnel.entitlements`.
5. PacketTunnel target settings: add `Libbox.xcframework` (Do Not Embed, it is
   static); add `-lresolv` to Other Linker Flags; sign with your team and
   `<bundle id>.PacketTunnel`; point Code Signing Entitlements at
   `PacketTunnel/PacketTunnel.entitlements`; deployment target macOS 12+; wrapper
   `systemextension`.
6. Runner target > Build Phases > new Copy Files phase, Destination = System
   Extensions, adding `PacketTunnel.systemextension`.
7. Runner target settings: your team, `<bundle id>`, `DebugProfile.entitlements`
   for Debug and `Release.entitlements` for Release.
8. During development you can run a dev-signed system extension without
   notarization: `systemextensionsctl developer on`.

## Build and install

```bash
cd app
bash macos/install_release.sh
```

The script is driven by environment variables:

| Variable | Meaning |
|---|---|
| `AURORA_APPLE_TEAM` | Required. The team id the project is signed with. |
| `AURORA_DEVELOPER_ID` | Optional. If set, the built app must be signed by an identity containing this text. |
| `AURORA_NOTARY_PROFILE` | Optional. A `notarytool store-credentials` keychain profile. Without it, notarization is skipped with a message. |

Notarization matters: `sysextd` refuses to replace an already approved Developer
ID system extension with an un-notarized one, so without it a reinstall can
silently keep running the OLD extension. For local testing use
`systemextensionsctl developer on` instead.

> **Do not open** `build/macos/Build/Products/Release/aurora.app` directly. macOS
> only lets a host app in `/Applications` activate a System Extension; running
> the build copy gives `OSSystemExtensionErrorDomain code=3`, and Launch Services
> then lists two identical Aurora apps. The install script builds and verifies
> the signature, installs the single `/Applications/aurora.app`, writes
> `build/distribution/Aurora-macOS-<arch>-<version>-<build>.zip`, then
> unregisters and removes the raw build copy. Add `--skip-build` to install an
> existing release build.

The PacketTunnel target hard-codes `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION`, and `install_release.sh` refuses a release where they
differ from the app's. They are `1.0.0` and `1` to match `app/pubspec.yaml`
(`1.0.0+1`); update them together when you change the version.

First launch: one "System Extension Blocked" prompt (approve it in System
Settings > General > Login Items & Extensions > Network Extensions), then one
"Allow VPN Configuration" prompt on the first connect. After that no approvals
are needed.

## Contract

Public builds embed no contract; add a server by importing an `aurora://` link in
the app. A private fork may place a contract at
`app/assets/configs/aurora-contract.json` (gitignored).

## Acceptance checklist

After installing on a real machine, check: the exit IP is the node's exit IP,
the tunnel fails closed when the node is unreachable, no approval is needed after
the first run, launch at login works, and the menu bar tray works.
