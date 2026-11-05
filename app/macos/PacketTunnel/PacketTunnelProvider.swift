import Foundation
import Libbox
import NetworkExtension

/// Aurora's NEPacketTunnelProvider.
///
/// Lifecycle (sing-box v1.13.12 libbox / command-server API):
///   1. App writes the compiled sing-box JSON into the shared App Group container.
///   2. iOS launches this extension; we LibboxSetup() with the container as base path,
///      cap memory (NE ~50MB limit), create a command server backed by AuroraPlatform,
///      then startOrReloadService(json). libbox calls back into AuroraPlatform.openTun()
///      to establish the TUN via NEPacketTunnelNetworkSettings.
/// Resumes a continuation exactly once, whoever gets there first.
///
/// Both the worker thread and the deadline timer race to finish a bounded call;
/// resuming a `CheckedContinuation` twice is a hard crash, so the winner is
/// decided under a lock.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let appGroupID = "group.com.aurora.vpn"
    static let configFileName = "config.json"

    /// The one command server this PROCESS owns, not this instance.
    ///
    /// NE builds a NEW provider object for every tunnel session while the macOS
    /// system extension process persists across all of them. libbox's command
    /// server binds a FIXED port (127.0.0.1:42813), so the server is a
    /// process-wide singleton whether we model it as one or not — and modelling
    /// it per-instance is what made that failure unrecoverable: session
    /// N's `stopTunnel` wedged before it could close the listener, session N+1
    /// got a fresh provider object whose `commandServer` was nil, so its
    /// stale-server cleanup had nothing to clean and `start()` died on
    /// EADDRINUSE — forever, for every subsequent connect, until the extension
    /// process was killed by hand.
    private static let sharedServerLock = NSLock()
    private static var sharedServer: LibboxCommandServer?

    /// What this process has bound, started and leaked, and whether that adds
    /// up to "only a restart can fix this". See TunnelProcessHealth.swift.
    private static let health = TunnelProcessHealth.shared

    /// Instance-level accessor over the process-wide server, so every existing
    /// call site keeps working while the invariant "one server per process"
    /// holds by construction instead of by convention.
    private var commandServer: LibboxCommandServer? {
        get {
            Self.sharedServerLock.lock()
            defer { Self.sharedServerLock.unlock() }
            return Self.sharedServer
        }
        set {
            Self.sharedServerLock.lock()
            defer { Self.sharedServerLock.unlock() }
            Self.sharedServer = newValue
        }
    }

    /// Atomically clears and returns the process-wide server, so two racing
    /// paths (a late `stopTunnel` and the next `startTunnel`) cannot both decide
    /// to release the same object.
    private static func takeSharedServer() -> LibboxCommandServer? {
        sharedServerLock.lock()
        defer { sharedServerLock.unlock() }
        let server = sharedServer
        sharedServer = nil
        return server
    }

    private lazy var platform = AuroraPlatform(provider: self)

    /// sing-box writes its log to stdout by default, which a system extension
    /// discards — every past failure left ZERO engine-side evidence. /tmp is
    /// writable by the non-sandboxed root extension and readable by the user,
    /// unlike the root App Group container.
    static let coreLogPath = "/tmp/aurora-core.log"

    /// Old NETunnelProvider profiles can survive app upgrades and omit the TUN
    /// MTU, which makes sing-box use its 4064-byte default. Normalize the JSON
    /// before libbox sees it so its gVisor stack and NetworkExtension both use
    /// the same Internet-safe MTU. Also route the core's log to a file so the
    /// engine is no longer a black box during connectivity failures.
    private func normalizedConfig(_ config: String) -> String {
        guard let data = config.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return config
        }
        var changed = false
        if var inbounds = root["inbounds"] as? [[String: Any]] {
            for index in inbounds.indices where inbounds[index]["type"] as? String == "tun" {
                let mtu = (inbounds[index]["mtu"] as? NSNumber)?.intValue
                if mtu.map({ (1280...1500).contains($0) }) != true {
                    inbounds[index]["mtu"] = 1400
                    changed = true
                    diag("normalized stale TUN mtu to 1400 before libbox startup")
                }
            }
            root["inbounds"] = inbounds
        }
        var log = (root["log"] as? [String: Any]) ?? [:]
        if log["output"] == nil {
            log["output"] = Self.coreLogPath
            root["log"] = log
            changed = true
        }
        guard changed else { return config }
        guard let normalizedData = try? JSONSerialization.data(withJSONObject: root),
              let normalized = String(data: normalizedData, encoding: .utf8) else {
            return config
        }
        return normalized
    }

    /// The core appends forever; cap the file so a chatty session cannot eat
    /// the disk. Called before each start, when nothing is writing to it.
    /// Also sanitizes the path first: this extension runs as ROOT and the core
    /// opens `log.output` following symlinks, so a pre-planted symlink in the
    /// sticky /tmp would let a local user redirect root-owned writes. Remove any
    /// symlink or non-root-owned file, then pre-create it root-owned so /tmp's
    /// sticky bit prevents replacement.
    private func prepareCoreLog() {
        let fm = FileManager.default
        let path = Self.coreLogPath
        if let attrs = try? fm.attributesOfItem(atPath: path) {
            let isSymlink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue
            if isSymlink || owner != 0 {
                try? fm.removeItem(atPath: path)
            } else if let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 {
                try? fm.removeItem(atPath: path + ".1")
                try? fm.moveItem(atPath: path, toPath: path + ".1")
            }
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
    }

    /// Appends a breadcrumb to <AppGroup>/diag.log AND a container-independent
    /// /tmp fallback (so we still get logs even if the App Group container is
    /// unreachable — e.g. under sandbox — when the container write is a no-op).
    private func diag(_ msg: String) {
        let line = "[ext] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/aurora-ext.log")) {
            defer { try? h.close() }; h.seekToEndOfFile(); h.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: "/tmp/aurora-ext.log"))
        }
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else { return }
        let url = c.appendingPathComponent("diag.log")
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// How long the graceful sing-box shutdown may take before we stop waiting
    /// on it. Measured against a real failure: closing a wedged Hysteria2
    /// outbound logged "close outbound ... take too much time to finish!" and
    /// never returned, so any unbounded wait here is a hang.
    private static let closeServiceTimeout: TimeInterval = 8
    /// Closing the listener touches no sing-box lock; if even this does not
    /// return promptly the process is unhealthy and the start path self-heals.
    private static let closeListenerTimeout: TimeInterval = 3

    /// Runs `body` off the caller's thread and reports whether it finished
    /// within `seconds`.
    ///
    /// A `false` return does NOT cancel `body` — a blocked cgo call into Go
    /// cannot be cancelled — it only means we stopped waiting for it. That is
    /// the entire point: the caller needs a bound, and the leaked work will
    /// finish (or not) on its own thread without holding the tunnel hostage.
    @discardableResult
    private static func runBounded(
        seconds: TimeInterval,
        _ body: @escaping () throws -> Void
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            Thread.detachNewThread {
                // Returning from a throwing close is not proof that the core
                // released its resources. Preserve the same poison boundary.
                do { try body(); gate.resume(true) }
                catch { gate.resume(false) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                gate.resume(false)
            }
        }
    }

    /// Releases `server` so its fixed TCP listener is free again, and reports
    /// whether the graceful service shutdown actually completed.
    ///
    /// Order and independence both matter here (libbox v1.13.14):
    ///   - `CloseService()` takes sing-box's `serviceAccess` lock and calls
    ///     `instance.Close()`. A stuck outbound blocks it indefinitely.
    ///   - `Close()` takes NO such lock: it stops the gRPC server, closes the
    ///     listener, then closes the subscribers.
    /// So `Close()` can free 42813 *while* `CloseService()` is still wedged —
    /// which is why the two are bounded separately instead of being chained on
    /// one thread. Chaining them is what leaked the listener: the second call
    /// simply never ran.
    /// Whichever of the two gives up first, the sing-box instance behind it is
    /// still running and still owns everything it acquired — the bbolt lock on
    /// `working/cache.db` above all. That is a leak of the whole instance, not
    /// of one resource, so it is recorded as poisoning the process rather than
    /// patched per-resource.
    @discardableResult
    private static func releaseServer(_ server: LibboxCommandServer) async -> Bool {
        let closedGracefully = await runBounded(seconds: closeServiceTimeout) {
            try server.closeService()
        }
        if !closedGracefully {
            extDiag("closeService failed or did not finish in \(Int(closeServiceTimeout))s; freeing listener anyway")
            health.markServiceLeaked("closeService failed or exceeded its \(Int(closeServiceTimeout))s bound")
        }
        let released = await runBounded(seconds: closeListenerTimeout) {
            server.close()
        }
        if !released {
            extDiag("command server close() did not finish in \(Int(closeListenerTimeout))s")
            health.markServiceLeaked("command server close() exceeded its \(Int(closeListenerTimeout))s bound")
        }
        return closedGracefully && released
    }

    /// Something this process can no longer reach still owns a resource every
    /// future start needs. Nothing in-process can free it, so every later start
    /// would fail identically — exiting is the only recovery, and NE relaunches
    /// the extension on the next connect. Delayed so a thrown error still
    /// reaches NE (and the user) before the process goes away.
    ///
    /// Only ever called through `TunnelProcessHealth`, which is what guarantees
    /// this stays a one-shot recovery instead of an exit loop.
    private static func restartExtension(_ reason: String) {
        extDiag("restarting extension process: \(reason)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            exit(EXIT_FAILURE)
        }
    }

    /// libbox surfaces the bind failure as a wrapped Go error string; there is
    /// no error code to match on. Used only to pick the recovery path, never to
    /// decide correctness.
    private static func isAddressInUse(_ error: Error) -> Bool {
        error.localizedDescription.contains("address already in use")
    }

    private func requireHealthyProcess() throws {
        // A previous session in this process leaked a live sing-box instance.
        // It still holds working/cache.db, so libbox would sit on bbolt's lock
        // and fail with "initialize cache-file: timeout" — as it did on every
        // connect until the sysext was killed by hand. The answer is known
        // already; spend the time on the restart instead of on the doomed open.
        if Self.health.isPoisoned {
            let reason = Self.health.poisonReason ?? "a previous shutdown did not finish"
            if Self.health.shouldRestartAfterStartFailure(addressInUse: false) {
                Self.restartExtension("start refused on a poisoned process: \(reason)")
            }
            diag("startTunnel: refused, process poisoned (\(reason))")
            throw AuroraError("tunnel engine is restarting after \(reason); connect again")
        }
    }

    override func startTunnel(options _: [String: NSObject]?) async throws {
        try requireHealthyProcess()
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw AuroraError("App Group container unavailable: \(Self.appGroupID)")
        }
        let basePath = container.path
        let workingPath = container.appendingPathComponent("working").path
        let tempPath = container.appendingPathComponent("temp").path
        try? FileManager.default.createDirectory(atPath: workingPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tempPath, withIntermediateDirectories: true)

        // Config source: on macOS the system extension runs as ROOT and does NOT
        // share the App Group container with the user-context app (they resolve to
        // /var/root/... vs ~user/...), so a shared file is invisible here. NE hands
        // the config across via providerConfiguration instead. Fall back to the
        // container file for iOS, where the container IS shared.
        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let rawConfigContent: String
        if let cfg = providerConfig?["config"] as? String, !cfg.isEmpty {
            rawConfigContent = cfg
            diag("startTunnel: config from providerConfiguration (\(cfg.count) bytes)")
        } else {
            let configURL = container.appendingPathComponent(Self.configFileName)
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                throw AuroraError("config not found: no providerConfiguration and no file at \(configURL.path)")
            }
            rawConfigContent = try String(contentsOf: configURL, encoding: .utf8)
            diag("startTunnel: config from container file (\(rawConfigContent.count) bytes)")
        }
        prepareCoreLog()
        let configContent = normalizedConfig(rawConfigContent)

        // Any server still registered belongs to a previous session that did not
        // finish releasing it — a start that threw after binding, or a stop that
        // wedged in sing-box's shutdown. macOS keeps the sysext process alive
        // across both (unlike iOS), so its Go listener is still holding
        // 127.0.0.1:42813 and every start from here on would fail with
        // EADDRINUSE. Reclaim it before asking for a new one.
        if let stale = Self.takeSharedServer() {
            diag("startTunnel: reclaiming command server leaked by a previous session")
            await Self.releaseServer(stale)
            platform.reset()
            // Reclaiming the old server can poison this process during this
            // start. Never open another core over that unfinished shutdown.
            try requireHealthyProcess()
        }

        let setup = LibboxSetupOptions()
        setup.basePath = basePath
        setup.workingPath = workingPath
        setup.tempPath = tempPath
        setup.logMaxLines = 3000
        // The CommandServer listens on 127.0.0.1 TCP + a secret: the unix socket
        // inside the root extension's container is unreachable from the
        // user-space app, and TCP sidesteps the container boundary. The app
        // generates the secret randomly per machine and delivers it through
        // providerConfiguration (an old profile without it falls back to the
        // historical constant, which the next config save by the app replaces).
        setup.commandServerListenPort = 42813
        setup.commandServerSecret =
            (providerConfig?["commandSecret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "aurora-cmd-7f3K9dQx2mVeLp81"
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError {
            diag("LibboxSetup FAILED: \(setupError.localizedDescription)")
            throw AuroraError("LibboxSetup failed: \(setupError.localizedDescription)")
        }
        diag("LibboxSetup ok")

        let stderrPath = container.appendingPathComponent("temp/stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(stderrPath, &stderrError)

        // macOS has no NetworkExtension memory cap (unlike iOS ~50MB); let libbox
        // use the default heap. gvisor stack still used for parity with mobile.
        LibboxSetMemoryLimit(false)

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &serverError) else {
            throw AuroraError("LibboxNewCommandServer failed: \(serverError?.localizedDescription ?? "unknown")")
        }
        commandServer = server
        // Any throw from here on must NOT leave the listener bound, or every
        // future start dies on EADDRINUSE until the sysext process restarts.
        do {
            try server.start()
            Self.health.markListenerBound()
            server.writeMessage(2, message: "(aurora) command server up")
            diag("command server started")
            try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
            Self.health.markServiceStarted()
            diag("startOrReloadService returned ok")
        } catch {
            diag("startTunnel FAILED, releasing command server: \(error.localizedDescription)")
            _ = Self.takeSharedServer()
            await Self.releaseServer(server)
            platform.reset()
            // Restart only when this process is known to have had something to
            // leak. A first start in a fresh process failing on a bad config or
            // a dead network gets reported, not respawned — otherwise the
            // self-heal becomes an exit loop.
            if Self.health.shouldRestartAfterStartFailure(addressInUse: Self.isAddressInUse(error)) {
                Self.restartExtension("start failed on a process that already ran a session: \(error.localizedDescription)")
            }
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        // Take the server out of the process registry FIRST. Whatever happens
        // below — including this task being abandoned by NE mid-shutdown — the
        // next startTunnel must not find a half-released object and assume the
        // port is its own to reuse.
        guard let server = Self.takeSharedServer() else {
            platform.reset()
            return
        }
        server.writeMessage(2, message: "(aurora) stopping: \(reason.rawValue)")
        let clean = await Self.releaseServer(server)
        platform.reset()
        if !clean {
            diag("stopTunnel: shutdown exceeded its bound (reason=\(reason.rawValue))")
        }
        // Retiring the process HERE, while the tunnel is already down, is what
        // keeps the recovery invisible: the poisoned process is gone before the
        // user asks to connect again, so the next start gets a clean one and
        // simply works. Waiting for that start to fail first would cost them a
        // visible failure for nothing.
        if Self.health.shouldRestartAfterStop() {
            Self.restartExtension(Self.health.poisonReason ?? "shutdown exceeded its bound")
        }
    }

    /// Bounded, best-effort core shutdown that leaves the command server bound
    /// and reusable. Used by callers that stop the sing-box service without
    /// ending the tunnel session.
    func stopService() async {
        guard let server = commandServer else {
            platform.reset()
            return
        }
        let closed = await Self.runBounded(seconds: Self.closeServiceTimeout) {
            try server.closeService()
        }
        if !closed {
            // This path deliberately keeps the session (and the listener) alive,
            // so it never reaches stopTunnel's recovery. Recording the leak is
            // what lets the next start catch it instead of inheriting a core
            // that still owns cache.db.
            diag("stopService: closeService failed or exceeded its bound")
            Self.health.markServiceLeaked("stopService's closeService failed or exceeded its \(Int(Self.closeServiceTimeout))s bound")
        }
        platform.reset()
    }

    func reloadService() throws {
        try requireHealthyProcess()
        reasserting = true
        defer { reasserting = false }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw AuroraError("App Group container unavailable")
        }
        let rawConfigContent = try String(contentsOf: container.appendingPathComponent(Self.configFileName), encoding: .utf8)
        let configContent = normalizedConfig(rawConfigContent)
        try commandServer?.startOrReloadService(configContent, options: LibboxOverrideOptions())
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }
}
