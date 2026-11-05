# iOS Runner session-boundary regression

Run locally on macOS:

```bash
bash app/ios/Runner/test/mobile/run.sh
```

The script extracts the complete production `AuroraVPN` and event-bridge classes,
removing only the module imports; NetworkExtension, Flutter and the libbox
CommandClient transport boundary use doubles. The App Group filesystem is isolated
too, so no real VPN, configuration or device is touched. The real CommandClient
class is verified separately for both iOS and macOS by
`app/macos/Runner/test/run.sh`.

The 35 assertions cover: adopting only an owned manager, an existing UUID,
single-flight, a stale UUID, system status notifications, manual cancellation, late
and duplicate replies, async preference retries, telemetry generations, terminal
failure, and release of the RPC owner. Deadlines are not shortened: the snapshot
and telemetry retirement take 3 seconds each, and reload's 25-second total budget
keeps a 3-second post-snapshot, so a full run takes about 30 seconds.

A single scenario can be passed, such as `short-deadlines` or `queued-stop`.
`AURORA_RUNNER_SOURCE` exists only for audits that need another production-source
snapshot to reproduce a RED run; by default the current working-tree files are
always read.

These are boundary regressions for production classes. They are not a real iOS SDK
compile or an on-device VPN verification. In Swift 5 mode the current Swift
compiler may report a Sendable warning for the CommandClient double; a real SDK
typecheck is a separate verification gate.
