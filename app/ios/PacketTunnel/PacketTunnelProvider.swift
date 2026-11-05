import Foundation
import CoreFoundation
import CryptoKit
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
/// Resumes a continuation exactly once, whoever gets there first (worker thread
/// or deadline timer). Resuming a `CheckedContinuation` twice is a hard crash.
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

private final class ReloadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "unavailable"
    func set(_ result: String) { lock.lock(); value = result; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let appGroupID = "group.com.aurora.vpn"
    static let configFileName = "config.json"

    /// Bound for the graceful sing-box shutdown. A wedged outbound ("close
    /// outbound ... take too much time to finish!") blocks `CloseService()`
    /// indefinitely, so waiting on it without a bound turns every stop into a
    /// hang. See the macOS provider for the failure this comes from.
    private static let closeServiceTimeout: TimeInterval = 8
    private static let closeListenerTimeout: TimeInterval = 3

    /// iOS usually tears the extension process down with the tunnel, which is
    /// why the leaked-instance failures were seen on macOS first. "Usually" is
    /// not "always" — NE is free to reuse a live extension for the next
    /// session, and a reused process that leaked a wedged sing-box carries the
    /// same permanently-held working/cache.db into it. Same policy, so the same
    /// type, kept byte-identical with the macOS copy (test/run.sh enforces it).
    private static let health = TunnelProcessHealth.shared

    private struct AuthenticationGrant {
        let requestID: String
        let callbackID: String
        let createdAt: Int64
    }

    private final class Session {
        let id: String
        var server: LibboxCommandServer
        let config: String
        var platform: AuroraPlatform
        let tailnetLease: AuroraTailnetStore.Lease?
        // callbackID belongs to sessionLock; core fields below belong only to
        // engineQueue. A Tailnet reload keeps the NE UUID and identity lease,
        // but every libbox platform gets a new callback identity.
        var callbackID: String?
        var authOwner: AuroraTailnetAuth.Owner?
        var authGrant: AuthenticationGrant?
        var coreMayExist = false
        var listenerClosed = false
        var cleanupUncertain = false
        var running = false
        var reloading = false

        init(id: String, server: LibboxCommandServer, config: String, platform: AuroraPlatform, tailnetLease: AuroraTailnetStore.Lease? = nil, authOwner: AuroraTailnetAuth.Owner? = nil) {
            self.id = id
            self.server = server
            self.config = config
            self.platform = platform
            self.tailnetLease = tailnetLease
            self.callbackID = id
            self.authOwner = authOwner
        }
    }

    private let tailnetAuth = AuroraTailnetAuth()
    private let sessionLock = NSLock()
    private let engineQueue = DispatchQueue(label: "aurora.ios.engine")
    private var session: Session?
    private var startIntent: String?
    private var starting = false
    private var retiring = false

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return try body()
    }

    private func owns(_ candidate: Session) -> Bool {
        locked { session === candidate && startIntent == candidate.id }
    }

    private func beginStart() throws -> String {
        try locked {
            guard !starting, !retiring, session == nil else {
                throw AuroraError("previous tunnel session is still active or stopping")
            }
            let id = UUID().uuidString
            starting = true
            startIntent = id
            return id
        }
    }

    private func finishStart(_ id: String) {
        locked {
            starting = false
            if session == nil && startIntent == id { startIntent = nil }
        }
    }

    /// Revocation takes effect before any potentially blocked core cleanup.
    private func retire(_ expected: Session? = nil, callbackID: String? = nil) -> Session? {
        locked {
            if let expected, session !== expected { return nil }
            if let callbackID, session?.callbackID != callbackID { return nil }
            startIntent = nil
            guard let old = session else { return nil }
            session = nil
            old.callbackID = nil
            invalidateAuthentication(old)
            retiring = true
            return old
        }
    }

    private func onEngine(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async {
                do { try body(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Nothing in-process can reclaim a wedged core, so the process itself is
    /// the reclaim boundary. NE relaunches the extension on the next connect.
    /// Delayed so the thrown error reaches the app first.
    private static func restartExtension(_ reason: String) {
        extDiag("restarting extension process: \(reason)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            exit(EXIT_FAILURE)
        }
    }

    /// Runs `body` off the caller's thread; `false` means it did not finish in
    /// time. It is NOT cancelled — a blocked cgo call cannot be — the caller
    /// simply stops waiting.
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

    /// Keep libbox's gVisor MTU aligned with the NetworkExtension MTU even when
    /// an old saved config omitted `inbounds[].mtu` and would otherwise inherit
    /// sing-box's 4064-byte default.
    private func normalizedConfig(_ config: String) -> String {
        guard let data = config.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var inbounds = root["inbounds"] as? [[String: Any]] else {
            return config
        }
        var changed = false
        for index in inbounds.indices where inbounds[index]["type"] as? String == "tun" {
            let mtu = (inbounds[index]["mtu"] as? NSNumber)?.intValue
            if mtu.map({ (1280...1500).contains($0) }) != true {
                inbounds[index]["mtu"] = 1400
                changed = true
            }
        }
        guard changed else { return config }
        root["inbounds"] = inbounds
        guard let normalizedData = try? JSONSerialization.data(withJSONObject: root),
              let normalized = String(data: normalizedData, encoding: .utf8) else {
            return config
        }
        diag("normalized stale TUN mtu to 1400 before libbox startup")
        return normalized
    }

    /// Appends a breadcrumb to <AppGroup>/diag.log (pullable via devicectl).
    private func diag(_ msg: String) {
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else { return }
        let url = c.appendingPathComponent("diag.log")
        let line = "[ext] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // Free the listener even when the core shutdown exceeds its bound.
    @discardableResult
    private func releaseServer(_ server: LibboxCommandServer) async -> Bool {
        let closedGracefully = await Self.runBounded(seconds: Self.closeServiceTimeout) {
            try self.engineQueue.sync { try server.closeService() }
        }
        if !closedGracefully {
            extDiag("closeService failed or did not finish in \(Int(Self.closeServiceTimeout))s; freeing listener anyway")
            Self.health.markServiceLeaked("closeService failed or exceeded its \(Int(Self.closeServiceTimeout))s bound")
        }
        let released = await Self.runBounded(seconds: Self.closeListenerTimeout) {
            server.close()
        }
        if !released {
            extDiag("command server close() did not finish in \(Int(Self.closeListenerTimeout))s")
            Self.health.markServiceLeaked("command server close() exceeded its \(Int(Self.closeListenerTimeout))s bound")
        }
        return closedGracefully && released
    }

    // Called only on engineQueue. An uncertain close is never retried: the Go
    // close path may have retained its mutex even when it returned an error.
    private func closeTailnetCore(_ candidate: Session) throws {
        guard !candidate.cleanupUncertain else { throw AuroraError("Tailnet core cleanup is uncertain") }
        do {
            if candidate.coreMayExist {
                try candidate.server.closeService()
                candidate.coreMayExist = false
            }
            if !candidate.listenerClosed {
                candidate.server.close()
                candidate.listenerClosed = true
            }
            candidate.platform.reset()
        } catch {
            candidate.cleanupUncertain = true
            Self.health.markServiceLeaked("Tailnet core close failed")
            if !candidate.listenerClosed {
                candidate.server.close()
                candidate.listenerClosed = true
            }
            candidate.platform.reset()
            throw AuroraError("Tailnet core close failed")
        }
    }

    private func release(_ retired: Session) async {
        if retired.tailnetLease != nil {
            // Stop drains an in-flight reload allocation on the same queue.
            // Only then is its final command server known and safe to release.
            let closed = await Self.runBounded(seconds: Self.closeServiceTimeout + Self.closeListenerTimeout) {
                try self.engineQueue.sync { try self.closeTailnetCore(retired) }
            }
            if closed { retired.tailnetLease?.closeAfterCoreClosed() }
            else { Self.health.markServiceLeaked("Tailnet core cleanup did not complete") }
        } else {
            await releaseServer(retired.server)
            retired.platform.reset()
        }
        locked { retiring = false }
    }

    // Caller holds sessionLock; the holder never reenters provider state.
    private func invalidateAuthentication(_ candidate: Session) {
        if let owner = candidate.authOwner { tailnetAuth.invalidate(owner) }
        candidate.authOwner = nil
        candidate.authGrant = nil
    }

    private func platform(_ id: String, owner: AuroraTailnetAuth.Owner?) -> AuroraPlatform {
        AuroraPlatform(provider: self, sessionID: id, safeLogs: owner != nil,
            tailnetNotification: owner.map { owner in { [weak self] notification in
                self?.locked {
                    guard let self, let current = self.session, current.authOwner === owner else { return }
                    if self.tailnetAuth.receive(owner, identifier: notification.identifier,
                        typeID: Int(notification.typeID), rawURL: notification.openURL) {
                        current.authGrant = nil
                    }
                }
            } })
    }

    private func replaceTailnetCore(_ candidate: Session) throws {
        // Revoke old callbacks before entering Go close. No old platform may
        // configure the tunnel, stop it, or reload the replacement core.
        locked { candidate.callbackID = nil }
        try closeTailnetCore(candidate)
        guard owns(candidate), !Self.health.isPoisoned else { throw AuroraError("Tailnet reload cancelled") }
        let callbackID = UUID().uuidString
        guard let node = candidate.tailnetLease?.prepared.nodeGeneration else { throw AuroraTailnetConfigFailure.invalidState }
        let owner = try tailnetAuth.beginOwner(sessionID: candidate.id, nodeGeneration: node)
        var ownerTransferred = false
        defer { if !ownerTransferred { tailnetAuth.invalidate(owner) } }
        let platform = platform(callbackID, owner: owner)
        var error: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &error) else {
            throw AuroraError("Tailnet core allocation failed")
        }
        // Publish engine-owned allocation even after a simultaneous stop, so
        // queued cleanup drains its observers without starting another core.
        candidate.server = server
        candidate.platform = platform
        candidate.listenerClosed = false
        guard locked({ () -> Bool in
            guard session === candidate, startIntent == candidate.id else { return false }
            candidate.callbackID = callbackID
            candidate.authOwner = owner
            ownerTransferred = true
            return true
        }) else { throw AuroraError("Tailnet reload cancelled") }
        try server.start()
        Self.health.markListenerBound()
        guard owns(candidate) else { throw AuroraError("Tailnet reload cancelled") }
        candidate.coreMayExist = true
        try server.startOrReloadService(candidate.config, options: LibboxOverrideOptions())
        Self.health.markServiceStarted()
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        let intent = try beginStart()
        defer { finishStart(intent) }
        // A reused process whose previous core never finished closing still
        // holds working/cache.db; libbox would only sit on bbolt's lock and
        // report "initialize cache-file: timeout". Restart instead of retrying.
        if Self.health.isPoisoned || Self.health.isRestartPending {
            let reason = Self.health.poisonReason ?? "a previous shutdown did not finish"
            if Self.health.shouldRestartAfterStartFailure(addressInUse: false) {
                Self.restartExtension("start refused on a poisoned process: \(reason)")
            }
            diag("startTunnel: refused, process poisoned (\(reason))")
            throw AuroraError("tunnel engine is restarting after \(reason); connect again")
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw AuroraError("App Group container unavailable: \(Self.appGroupID)")
        }
        let basePath = container.path
        let workingPath = container.appendingPathComponent("working").path
        let tempPath = container.appendingPathComponent("temp").path
        try? FileManager.default.createDirectory(atPath: workingPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tempPath, withIntermediateDirectories: true)

        let configURL = container.appendingPathComponent(Self.configFileName)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw AuroraError("config not found in App Group container: \(configURL.path)")
        }
        let rawConfigContent = try String(contentsOf: configURL, encoding: .utf8)
        diag("startTunnel: config read (\(rawConfigContent.count) bytes)")
        var configContent = normalizedConfig(rawConfigContent)
        var tailnetLease: AuroraTailnetStore.Lease?
        var leaseTransferred = false
        defer { if !leaseTransferred { tailnetLease?.closeAfterCoreClosed() } }
        if let options, options.keys.contains(where: { $0.hasPrefix("tailnet") }) {
            guard Set(options.keys) == ["tailnetSettingsGeneration", "tailnetNodeGeneration", "tailnetConfigSHA256"],
                  let generation = options["tailnetSettingsGeneration"] as? NSNumber,
                  CFGetTypeID(generation) != CFBooleanGetTypeID(),
                  !["d", "f"].contains(String(cString: generation.objCType)),
                  let expected = Int64(generation.stringValue), expected >= 0,
                  let node = options["tailnetNodeGeneration"] as? String,
                  let digest = options["tailnetConfigSHA256"] as? String,
                  digest == SHA256.hash(data: Data(rawConfigContent.utf8)).map({ String(format: "%02x", $0) }).joined() else {
                throw AuroraTailnetConfigFailure.invalidState
            }
            let store = AuroraTailnetStore(container: container)
            let settings = try store.readSettings()
            guard settings.enabled, settings.settingsGeneration == expected, settings.nodeGeneration == node,
                  let prepared = try store.prepareStart(expected) else { throw AuroraTailnetStoreFailure.stale }
            // The same cross-process lease protects the identity until Go close
            // is positively complete, even if NE already reports disconnected.
            tailnetLease = try store.acquireSessionLease(prepared, sessionID: intent)
            configContent = try AuroraTailnetConfig.validate(configContent, prepared: prepared)
            guard locked({ startIntent == intent }) else { throw AuroraTailnetStoreFailure.stale }
        } else if let root = try? JSONSerialization.jsonObject(with: Data(rawConfigContent.utf8)) as? [String: Any],
                  let endpoints = root["endpoints"] as? [[String: Any]],
                  endpoints.contains(where: { $0["type"] as? String == "tailscale" }) {
            throw AuroraTailnetConfigFailure.invalidState
        }

        let setup = LibboxSetupOptions()
        setup.basePath = basePath
        setup.workingPath = workingPath
        setup.tempPath = tempPath
        setup.logMaxLines = 3000
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError {
            let failure = tailnetLease == nil ? setupError.localizedDescription : "Tailnet setup failed"
            diag("LibboxSetup FAILED: \(failure)")
            throw AuroraError("LibboxSetup failed: \(failure)")
        }
        diag("LibboxSetup ok")

        let stderrPath = container.appendingPathComponent("temp/stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(stderrPath, &stderrError)

        // Honour the iOS extension memory limit (gvisor stack + this keeps us < 50MB).
        LibboxSetMemoryLimit(true)

        var serverError: NSError?
        let authOwner = try tailnetLease.map { try tailnetAuth.beginOwner(sessionID: intent, nodeGeneration: $0.prepared.nodeGeneration) }
        var authTransferred = false
        defer { if !authTransferred, let authOwner { tailnetAuth.invalidate(authOwner) } }
        let platform = platform(intent, owner: authOwner)
        guard let server = LibboxNewCommandServer(platform, platform, &serverError) else {
            let failure = tailnetLease == nil ? (serverError?.localizedDescription ?? "unknown") : "Tailnet core allocation failed"
            throw AuroraError("LibboxNewCommandServer failed: \(failure)")
        }
        // From allocation onward, only confirmed native cleanup releases it.
        // Dropping an uncertain lease deliberately keeps its OS lock until exit.
        leaseTransferred = true
        let candidate = Session(id: intent, server: server, config: configContent, platform: platform, tailnetLease: tailnetLease, authOwner: authOwner)
        guard locked({ () -> Bool in
            guard startIntent == intent else { return false }
            session = candidate
            authTransferred = true
            return true
        }) else {
            // NewCommandServer already allocated observers, even before start.
            let closed = await Self.runBounded(seconds: Self.closeListenerTimeout) { server.close() }
            if closed { tailnetLease?.closeAfterCoreClosed() }
            if !closed {
                Self.health.markServiceLeaked("cancelled server allocation did not close")
                if Self.health.shouldRestartAfterStop() {
                    Self.restartExtension("cancelled server allocation did not close")
                }
            }
            throw AuroraError("tunnel start cancelled")
        }
        do {
            try await onEngine {
                guard self.owns(candidate), !Self.health.isPoisoned else {
                    throw AuroraError("tunnel start cancelled")
                }
                try server.start()
                Self.health.markListenerBound()
                server.writeMessage(2, message: "(aurora) command server up")
                self.diag("command server started")
                guard self.owns(candidate) else { throw AuroraError("tunnel start cancelled") }
                candidate.coreMayExist = true
                try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
                Self.health.markServiceStarted()
                guard self.locked({ () -> Bool in
                    guard self.session === candidate else { return false }
                    candidate.running = true
                    return true
                }) else { throw AuroraError("tunnel start cancelled") }
                self.diag("startOrReloadService returned ok")
            }
        } catch {
            let failure = tailnetLease == nil ? error.localizedDescription : "Tailnet core start failed"
            diag("startTunnel FAILED, releasing command server: \(failure)")
            let reported: Error = tailnetLease == nil ? error : AuroraError(failure)
            guard let retired = retire(candidate) else { throw reported }
            let restartClaimed = Self.health.shouldRestartAfterStartFailure(addressInUse: false)
            await release(retired)
            // Only when this process already ran a session — a first start
            // failing in a fresh process is a config or network problem that a
            // respawn cannot fix, and exiting on it would be a loop.
            if restartClaimed || Self.health.shouldRestartAfterStartFailure(addressInUse: false) {
                Self.restartExtension("start failed on a process that already ran a session: \(failure)")
            }
            throw reported
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        diag("stopTunnel: reason=\(reason.rawValue)")
        guard let retired = retire() else { return }
        if retired.tailnetLease == nil { retired.server.writeMessage(2, message: "(aurora) stopping: \(reason.rawValue)") }
        await release(retired)
        // Retire the process while the tunnel is already down, so a reused
        // process can never hand a wedged core to the next session.
        if Self.health.shouldRestartAfterStop() {
            Self.restartExtension(Self.health.poisonReason ?? "shutdown exceeded its bound")
        }
    }

    /// Capture the callback's owner before dispatching asynchronous cleanup.
    /// A retired core must never stop a later manually created session.
    func requestServiceStop(_ id: String) {
        guard let retired = retire(callbackID: id) else { return }
        cancelTunnelWithError(nil)
        Task {
            await release(retired)
            if Self.health.shouldRestartAfterStop() {
                Self.restartExtension(Self.health.poisonReason ?? "shutdown exceeded its bound")
            }
        }
    }

    private func sessionSnapshot() -> [String: Any] {
        locked {
            guard let current = session, current.running,
                  !Self.health.isPoisoned, !Self.health.isRestartPending else {
                return ["status": "disconnected"]
            }
            return ["status": current.reloading ? "connecting" : "connected", "sessionId": current.id]
        }
    }

    private func tailnetSnapshot() -> [String: Any] {
        locked {
            guard let current = session, let lease = current.tailnetLease else {
                return ["schema": 1, "sessionId": NSNull(), "nodeGeneration": NSNull(),
                    "publicStatus": session.map { current in
                        if Self.health.isPoisoned || Self.health.isRestartPending { return "error" }
                        return current.running && !current.reloading ? "connected" : "connecting"
                    } ?? "disconnected",
                    "tailnetStatus": "disabled", "authAvailable": false]
            }
            let healthy = !Self.health.isPoisoned && !Self.health.isRestartPending
            let running = current.running && !current.reloading && healthy
            let available = running && current.authOwner.map { tailnetAuth.authenticationRequired($0) } == true
            return ["schema": 1, "sessionId": current.id, "nodeGeneration": lease.prepared.nodeGeneration,
                "publicStatus": healthy ? (running ? "connected" : "connecting") : "error",
                "tailnetStatus": !healthy ? "error" : (!running ? "starting" : (available ? "needsLogin" : "unverified")),
                "authAvailable": available]
        }
    }

    // These messages are native host↔extension RPCs. Only the snapshot above is
    // returned to Dart. URL transfer is one use, bound to the current platform;
    // the host must validate it again and check its own foreground/deadline
    // immediately before UIApplication.open.
    private func transferAuthentication(_ body: [String: Any]) -> [String: Any] {
        locked {
            guard Set(body.keys) == ["method", "sessionId", "nodeGeneration", "requestId"],
                  let requestID = body["requestId"] as? String, UUID(uuidString: requestID) != nil,
                  let current = session, current.running, !current.reloading,
                  !Self.health.isPoisoned, !Self.health.isRestartPending,
                  current.id == body["sessionId"] as? String,
                  current.tailnetLease?.prepared.nodeGeneration == body["nodeGeneration"] as? String,
                  let callbackID = current.callbackID, let owner = current.authOwner,
                  let ticket = tailnetAuth.requestOpen(owner, userGesture: true) else { return ["result": "unavailable"] }
            var response: [String: Any] = ["result": "unavailable"]
            let sent = tailnetAuth.dispatchOpen(ticket) { url in
                response = ["result": "ready", "url": url, "callbackId": callbackID, "requestId": requestID]
            }
            if sent == .opened {
                current.authGrant = AuthenticationGrant(requestID: requestID, callbackID: callbackID,
                    createdAt: AuroraTailnetAuth.elapsedRealtimeMillis())
            }
            return response
        }
    }

    private func validateAuthentication(_ body: [String: Any]) -> Bool {
        locked {
            guard Set(body.keys) == ["method", "sessionId", "nodeGeneration", "requestId", "callbackId"],
                  let current = session, current.running, !current.reloading,
                  !Self.health.isPoisoned, !Self.health.isRestartPending,
                  current.id == body["sessionId"] as? String,
                  current.tailnetLease?.prepared.nodeGeneration == body["nodeGeneration"] as? String,
                  let grant = current.authGrant,
                  grant.requestID == body["requestId"] as? String,
                  grant.callbackID == body["callbackId"] as? String,
                  current.callbackID == grant.callbackID else { return false }
            current.authGrant = nil
            let now = AuroraTailnetAuth.elapsedRealtimeMillis()
            return now >= grant.createdAt && now - grant.createdAt < 4_000
        }
    }

    /// Only messages to this already-running provider can request recovery.
    /// Neither this endpoint nor its caller creates a new system VPN session.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard messageData.count <= 8192,
              let body = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any] else {
            completionHandler?(nil)
            return
        }
        func reply(_ body: [String: Any]) {
            completionHandler?(try? JSONSerialization.data(withJSONObject: body))
        }
        switch body["method"] as? String {
        case "tailnetSnapshot":
            guard Set(body.keys) == ["method"] else { completionHandler?(nil); return }
            reply(tailnetSnapshot())
        case "tailnetAuthentication":
            reply(transferAuthentication(body))
        case "tailnetAuthenticationValidate":
            reply(["valid": validateAuthentication(body)])
        case "sessionSnapshot":
            reply(sessionSnapshot())
        case "reloadCurrentSession":
            guard let id = body["sessionId"] as? String, !id.isEmpty else {
                reply(["result": "unavailable"])
                return
            }
            Task { reply(["result": await reloadCurrentSession(id)]) }
        default:
            completionHandler?(nil)
        }
    }

    private func reloadCurrentSession(_ id: String, expectedCallbackID: String? = nil) async -> String {
        guard let candidate = locked({ () -> Session? in
            guard let current = session, current.id == id, current.running,
                  !current.reloading, !Self.health.isPoisoned, !Self.health.isRestartPending else { return nil }
            if let expectedCallbackID, current.callbackID != expectedCallbackID { return nil }
            current.reloading = true
            if current.tailnetLease != nil { invalidateAuthentication(current) }
            return current
        }) else { return "unavailable" }
        defer { locked { candidate.reloading = false } }
        let outcome = ReloadOutcome()
        let finished = await Self.runBounded(seconds: 12) {
            self.engineQueue.sync {
                guard self.owns(candidate), !Self.health.isPoisoned else { return }
                do {
                    // Retain the config belonging to this session. A later
                    // manual connect may already have replaced config.json.
                    if candidate.tailnetLease != nil { try self.replaceTailnetCore(candidate) }
                    else { try candidate.server.startOrReloadService(candidate.config, options: LibboxOverrideOptions()) }
                    outcome.set("reloaded")
                } catch {
                    self.diag(candidate.tailnetLease == nil ? "current session reload failed: \(error.localizedDescription)" : "Tailnet core reload failed")
                    outcome.set("requiresReconnect")
                }
            }
        }
        guard owns(candidate) else { return "unavailable" }
        if finished && outcome.get() == "reloaded" { return "reloaded" }

        if !finished {
            Self.health.markServiceLeaked("current-session reload exceeded its 12s bound")
        }
        guard let retired = retire(candidate) else { return "unavailable" }
        // Reserve process retirement before cleanup can release admission.
        // Otherwise a new manual start can race the async return from release.
        let restartClaimed = Self.health.shouldRestartAfterStartFailure(addressInUse: false)
        cancelTunnelWithError(AuroraError("tunnel recovery requires an explicit reconnect"))
        await release(retired)
        if restartClaimed || Self.health.shouldRestartAfterStartFailure(addressInUse: false) {
            Self.restartExtension("current-session recovery could not finish safely")
        }
        return "requiresReconnect"
    }

    /// The libbox control callback follows the same ownership and timeout rules.
    func reloadService(_ id: String) throws {
        guard let currentID = locked({ () -> String? in
            guard let current = session, current.callbackID == id, current.running,
                  !current.reloading, !Self.health.isPoisoned, !Self.health.isRestartPending else { return nil }
            return current.id
        }) else {
            throw AuroraError("no running tunnel session to reload")
        }
        let done = DispatchSemaphore(value: 0)
        let outcome = ReloadOutcome()
        Task {
            outcome.set(await reloadCurrentSession(currentID, expectedCallbackID: id))
            done.signal()
        }
        guard done.wait(timeout: .now() + 25) == .success,
              outcome.get() == "reloaded" else {
            throw AuroraError("current tunnel session could not be reloaded")
        }
    }

    func canConfigureTunnel(_ id: String) -> Bool {
        locked {
            guard let current = session else { return false }
            return current.callbackID == id && startIntent == current.id && !Self.health.isPoisoned
        }
    }

    override func sleep() async {
        guard let current = locked({ session }) else { return }
        try? await onEngine { if self.owns(current) { current.server.pause() } }
    }

    override func wake() {
        guard let current = locked({ session }) else { return }
        engineQueue.async { if self.owns(current) { current.server.wake() } }
    }
}
