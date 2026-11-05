# Contributing to Aurora

Thanks for helping. Please read this first: most of it exists because something broke.

## Ground rules

- **English only**, in code, comments, UI text and docs.
- **Never commit a secret.** Real UUIDs, keys, passwords and tokens live on your servers and in your
  device's encrypted storage. Fixtures use placeholders and documentation addresses (`203.0.113.x`,
  `198.51.100.x`, `example.com`). `scripts/check-repo-policy.sh` enforces part of this; `.gitignore`
  blocks common secret files, so do not weaken it.
- **Verify the exit, not connectivity.** "It connects" proves little. A route that works but exits
  from the wrong place looks perfectly healthy and is worse than a dead one. After changing anything
  in the data path, check where traffic really comes out (`scripts/verify-egress.sh`).
- Keep the reason a line exists in a comment when the reason is not obvious from the code. Assume
  whoever reads it next is debugging an outage.

## Running the tests

| What | Command |
| --- | --- |
| Flutter app | `cd app && flutter pub get && flutter analyze && flutter test` |
| Node installer | `SING_BOX=/path/to/sing-box bash deploy/test/installer-test.sh` |
| Installer to app compiler, with real traffic | `SING_BOX=/path/to/sing-box bash deploy/test/contract-e2e-test.sh` |
| Desktop service | `cd desktop/aurora-svc && go test ./... && GOOS=windows go vet ./... && GOOS=linux go vet ./...` |
| Control plane | `cd control-plane && node --test` |
| Edge agents | `cd edge-agent && go test ./...` |
| Repository policy | `bash scripts/check-repo-policy.sh` |
| The whole user journey, on every platform | `gh workflow run full-flow -f packages_run=<id of a release run>` |

The installer tests need no root and never touch services, firewalls or your router, so they are
safe on a machine that is already a production node. They run real sing-box instances on high
loopback ports and send real HTTPS requests through them, so they need internet access.

## Hard constraints

Violating these is a bug. Each one comes from a real failure; `docs/reliability-notes.md` has the
stories.

1. **Never commit secrets.** See above.

2. **Don't fork sing-box.** Use the `experimental/libbox` release library and build tags only
   (`with_gvisor,with_quic,with_utls,with_clash_api`; Android adds
   `badlinkname,tfogo_checklinkname0`).

3. **TUN addresses are per platform.** Android, Windows and Linux use `172.19.0.1/30` plus
   `fdfe:dcba:9876::1/126`. iOS and macOS use the small `10.111.222.1/24` plus
   `fdfe:dcba:9876::1/64` because of the Network Extension memory limit. The host addresses are defined
   once, as `auroraTunHostAddresses` in `config_compiler.dart`, and `physical_network.dart` uses them to
   keep the tunnel out of the physical-network signature. Change them there and nowhere else.

4. **Use sing-box 1.13.x routing**: `{"action":"sniff"}`, `{"action":"hijack-dns"}` and
   `route.default_domain_resolver`. `app/test/fixtures/expected-*.json` is the structural baseline.
   Changing compiler output means updating those fixtures **and** re-validating with `sing-box check`.

5. **Rule sets are embedded** (`app/assets/rule_sets/`, referenced as `local`, extracted by
   `rule_sets.dart`). Never fetch them from GitHub at runtime: it is unreachable from some of the
   networks this exists for.

6. **No telemetry.** No analytics, no crash reporting, no third-party SDK that phones home. This also
   rules out dependencies that bring telemetry in with them, such as ML Kit based QR scanners. That is
   why QR import goes through the system camera and a deep link.

7. **Never pass a filesystem path across the Windows privilege boundary.** `aurora-svc` runs as
   LocalSystem and the app as the logged-in user, so `%APPDATA%`, `%USERPROFILE%` and `%TEMP%` resolve
   differently in the two processes. Send the config bytes, and derive shared locations only from
   machine-wide variables (`%ProgramData%`). The same trap exists on Linux with `$HOME` and `$XDG_*`,
   which is why `desktop/aurora-svc/paths_linux.go` hard-codes `/var/lib/aurora`.

8. **`auroraTunInterfaceName` (`"aurora0"`) is defined twice and must change in lockstep**: in Dart
   (`app/lib/core/config_compiler.dart`) and in Go (`desktop/aurora-svc/tunnel_gone.go`). Change one
   without the other and the Go side polls for an interface sing-box was never told to create.

9. **`ipv6_mode: block` means the desktop TUN gets no IPv6 address.** sing-tun only installs its WFP
   "block all IPv6" filter when the TUN has no IPv6 address, so giving it one while claiming to block
   IPv6 silently disables the only kernel-level backstop. Route rules can only reject IPv6 that already
   entered the tunnel.

10. **`route.default_interface` and `route.auto_detect_interface` are mutually exclusive.** sing-box
    ignores `default_interface` when auto-detection is on, so the compiler emits exactly one. The pinned
    name comes from `/diagnose`'s interface table (the same FriendlyName sing-box resolves), never from
    Dart's `NetworkInterface.list()`.

11. **`app/lib/cli/` and `app/bin/` stay free of Flutter imports.** They compile with `dart build cli`
    into a binary that runs with no display, and one `package:flutter/*` import breaks that.
    `app/test/cli_purity_test.dart` enforces it. Logic shared by the GUI and the CLI belongs in a pure
    module under `app/lib/core/`.

12. **The default route is resolved in exactly one place**: `resolveAuroraMode`,
    `resolveRouteFamilySelection` and `resolveDefaultRouteTarget` in `app/lib/core/route_family.dart`,
    for the GUI and the CLI alike. A saved user choice wins. Storing **auto** must write the explicit
    string `'auto'` rather than clear the key: a cleared key means "never chose" and resolves to the
    default again.

13. **Shadowsocks outbounds never carry `multiplex`.** sing-mux dials new sessions and inspects existing
    ones under one client-wide lock, so a single stuck write freezes every new connection on that leg,
    including the DoH dial queued behind it, which means machine-wide DNS, and tunnel shutdown too. The
    compiler ignores `multiplex: true` and emits `udp_over_tcp: true` instead, because a relay only
    forwards TCP.

14. **A Hysteria2 node's `server_ports` lists only ports verified reachable from outside.** The client
    hops to a random listed port with no health check, so one blocked port in the list is a periodic
    outage and a blocked range is a dead leg. The default is source-port hopping on the one known port
    (`"443:443"`), which needs no server change. `deploy/extras/hy2-port-hopping.sh` explains how to
    verify a range before advertising it.

15. **A route family is never inferred from structure that cannot prove it.** A node with no `detour`
    has no relay hop; that does not prove it exits where you think. `AuroraNode.via` falls back to
    `relay` when there is a detour and `unspecified` otherwise, never `direct`. `role: entry` nodes are
    never selectable: only their chained exits are. An entry that could also be an exit would quietly
    move the user's public IP while the UI stays green.

16. **The Windows start budget (`ReadyTimeout`, 45 s) must stay far above 10 s.** Readiness sits behind
    `wintun.CreateAdapter`, a device install, and sing-box waits up to `C.StartTimeout` (10 s) on its own.
    Killing the core during that window leaves a half-created adapter behind.

17. **`/status` and `/diagnose` send `charset=utf-8` and the client decodes with `utf8.decode` anyway.**
    Windows adapter names and error strings are localized, and Dart's `http` package decodes a charset-less
    body as latin-1. A mangled adapter name is one sing-box can never resolve.

18. **`install.sh` must stay safe under `curl | bash`.** Everything lives in functions and `main` runs on
    the last line, so a truncated download executes nothing. Keep it a single file, compatible with
    bash 3.2, and never let test mode touch services, firewalls or the router.

## Pull requests

- Keep changes focused, and explain why in the description.
- New behaviour needs a test. Bug fixes need a test that fails without the fix.
- Run `flutter analyze` and the relevant suites above. CI runs everything, including a real install of
  `install.sh` on a clean Ubuntu runner.
- `app/` sources are not `dart format` clean: do not run it across files you did not otherwise change,
  or the diff becomes unreadable.
