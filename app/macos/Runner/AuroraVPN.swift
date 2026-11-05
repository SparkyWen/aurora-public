import AppKit
import FlutterMacOS
import Foundation
import Libbox
import NetworkExtension

/// App-side VPN control + live telemetry bridge.
///
/// Implements the SAME Flutter channel contract as Android:
///   - MethodChannel  `aurora/method`  : prepare/start/stop/status/queryStats/
///                                        selectOutbound/urlTest/openVpnSettings
///                                        (+ iOS-only appGroupContainer/readDiag)
///   - EventChannel   `aurora/events`  : NEVPNStatus → AuroraStatus
///   - EventChannel   `aurora/stats`   : live traffic (libbox StatusMessage)
///   - EventChannel   `aurora/groups`  : outbound groups / urltest delays
///
/// Lifecycle: the app compiles the sing-box JSON (Dart ConfigCompiler) and hands
/// it to `start`; we persist it into the App Group container and bring up the
/// NETunnelProviderManager. The PacketTunnel extension reads that JSON and runs
/// libbox. Once connected, we attach a libbox `CommandClient` to the extension's
/// in-extension `CommandServer` (over the shared App Group socket) to stream
/// traffic + node groups and to drive select/urltest.
final class AuroraVPN: NSObject {
    static let appGroupID = "group.com.aurora.vpn"
    static let providerBundleID = "com.aurora.vpn.PacketTunnel"
    static let displayName = "Aurora"
    static let configFileName = "config.json"
    // macOS only: CommandServer/Client use 127.0.0.1 TCP + a secret. The system
    // extension runs as root and the unix socket in its container is unreachable
    // from the user-space app; libbox's CommandServerListenPort binds only
    // 127.0.0.1 (command_server.go).
    // The secret is generated randomly per machine and stored in the App Group
    // container (0600), then passed to the extension via providerConfiguration.
    // It must not be a constant in the repo, or any local process could send
    // stop/reload commands to port 42813.
    static let commandPort: Int32 = 42813
    static let commandSecret = loadOrCreateCommandSecret()
    private static let legacyCommandSecret = "aurora-cmd-7f3K9dQx2mVeLp81"

    private static func loadOrCreateCommandSecret() -> String {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return legacyCommandSecret
        }
        let url = container.appendingPathComponent("command-secret")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 32 { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return legacyCommandSecret
        }
        let secret = "aurora-" + bytes.map { String(format: "%02x", $0) }.joined()
        try? Data(secret.utf8).write(to: url, options: .withoutOverwriting)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        // Re-read: if a concurrent first-run (GUI + install CLI) already wrote a
        // different secret, adopt the winner so both processes converge instead
        // of the extension and client ending up with divergent secrets.
        if let winner = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = winner.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 32 { return trimmed }
        }
        return secret
    }

    /// Installs a compiled sing-box config into the existing macOS VPN profile.
    ///
    /// This is used by the signed host app's deployment CLI
    /// (`--install-runtime-config`) so a machine can be repaired even when the
    /// saved NETunnelProvider profile predates the current Dart compiler. A
    /// plain `scutil --nc start` only reuses the stale providerConfiguration;
    /// updating the App Group file alone is insufficient because the macOS
    /// system extension runs in the root context.
    /// Tear the tunnel down on app quit so no full-tunnel session lingers after
    /// the GUI exits — a stopped provider hands the physical default route back,
    /// so quitting Aurora stops intercepting other apps' traffic. Bounded wait
    /// (≤3s) keeps applicationShouldTerminate from hanging the quit.
    static func stopForTermination() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let manager = managers.first else { return }
        let status = manager.connection.status
        if status == .disconnected || status == .invalid { return }
        manager.connection.stopVPNTunnel()
        for _ in 0..<30 {
            let current = manager.connection.status
            if current == .disconnected || current == .invalid { break }
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        }
    }

    static func installRuntimeConfig(_ configJson: String, shouldStart: Bool) async throws {
        guard !configJson.isEmpty,
              let data = configJson.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw AuroraVPNError("runtime config is empty or not a JSON object")
        }

        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            try data.write(
                to: container.appendingPathComponent(configFileName),
                options: .atomic
            )
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()
        if manager.connection.status != .disconnected &&
            manager.connection.status != .invalid {
            manager.connection.stopVPNTunnel()
            for _ in 0..<50 {
                if manager.connection.status == .disconnected ||
                    manager.connection.status == .invalid {
                    break
                }
                try await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            }
        }

        applyProtocol(manager, config: configJson)
        try await saveRetryingStale(manager, config: configJson)
        try await manager.loadFromPreferences()

        if shouldStart {
            try manager.connection.startVPNTunnel()
        }
        diag(
            "runtime config installed (\(configJson.count) bytes, start=\(shouldStart))"
        )
    }

    private let methodChannel: FlutterMethodChannel
    private let statusChannel: FlutterEventChannel
    private let statsChannel: FlutterEventChannel
    private let groupsChannel: FlutterEventChannel

    // Retained stream handlers (one per EventChannel).
    private var streamHandlers: [AuroraStreamHandler] = []

    private var statusSink: FlutterEventSink?
    private var statsSink: FlutterEventSink?
    private var groupsSink: FlutterEventSink?
    private var statusObserver: NSObjectProtocol?
    private var lastPushedStatus: String?

    /// NE's own verdict on why the last session ended, captured on the
    /// `.disconnected` transition and cleared on every start so Dart only ever
    /// reads the reason for the attempt it just made. "No network available"
    /// lives only here: NE refuses such a start before the extension process
    /// is even spawned, so no extension log line exists for it.
    private var lastDisconnectDetail: String?

    /// One retained manager for status/stop queries. Every
    /// `loadAllFromPreferences()` call materializes fresh NEVPNConnection
    /// objects that each re-post NEVPNStatusDidChange for the same session —
    /// per-call loading made the duplicate notifications grow with every
    /// reconnect (observed 12 → 20 → 23 duplicate events per status change).
    private var cachedManager: NETunnelProviderManager?

    private func loadManager() async -> NETunnelProviderManager? {
        if let cachedManager { return cachedManager }
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        cachedManager = managers.first
        return cachedManager
    }

    private var commandClient: AuroraCommandClient?
    private var lastStats: [String: Any] = [:]
    private let commandStateLock = NSLock()
    private var desiredSelections: [String: String] = [:]
    private var pendingURLTests: Set<String> = []

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(name: "aurora/method", binaryMessenger: messenger)
        statusChannel = FlutterEventChannel(name: "aurora/events", binaryMessenger: messenger)
        statsChannel = FlutterEventChannel(name: "aurora/stats", binaryMessenger: messenger)
        groupsChannel = FlutterEventChannel(name: "aurora/groups", binaryMessenger: messenger)
        super.init()

        // The app's CommandClient must derive the SAME unix-socket path the
        // extension's CommandServer listens on, so both call LibboxSetup with the
        // identical App Group base/working/temp paths.
        AuroraVPN.libboxSetup()

        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result)
        }

        let statusHandler = AuroraStreamHandler(
            onListen: { [weak self] sink in self?.attachStatus(sink) },
            onCancel: { [weak self] in self?.detachStatus() })
        let statsHandler = AuroraStreamHandler(
            onListen: { [weak self] sink in self?.statsSink = sink },
            onCancel: { [weak self] in self?.statsSink = nil })
        let groupsHandler = AuroraStreamHandler(
            onListen: { [weak self] sink in self?.groupsSink = sink },
            onCancel: { [weak self] in self?.groupsSink = nil })
        streamHandlers = [statusHandler, statsHandler, groupsHandler]
        statusChannel.setStreamHandler(statusHandler)
        statsChannel.setStreamHandler(statsHandler)
        groupsChannel.setStreamHandler(groupsHandler)
    }

    // MARK: - method dispatch

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        // FlutterResult MUST be invoked on the platform (main) thread; a bare
        // Task hops to the concurrent executor and the darwin embedder may drop
        // the reply — exactly the calls the Dart connect pipeline awaits.
        switch call.method {
        case "prepare":
            Task { @MainActor in
                do { result(try await self.prepare()) }
                catch { result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil)) }
            }
        case "start":
            let config = (call.arguments as? [String: Any])?["config"] as? String
            Task { @MainActor in
                do {
                    try await self.start(config)
                    result(nil)
                } catch {
                    AuroraVPN.diag("start ERROR: \(error.localizedDescription)")
                    result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
                }
            }
        case "stop":
            AuroraVPN.diag("Flutter method stop requested")
            Task { @MainActor in await self.stop(); result(nil) }
        case "status":
            Task { @MainActor in result(await self.currentStatusString()) }
        case "queryStats":
            result(lastStats)
        case "selectOutbound":
            let args = call.arguments as? [String: Any]
            guard let g = args?["group"] as? String, !g.isEmpty,
                  let t = args?["tag"] as? String, !t.isEmpty else {
                result(FlutterError(code: "invalid_selection", message: "selector arguments are required", details: nil))
                return
            }
            do {
                try queueSelection(group: g, tag: t)
                result(nil)
            } catch {
                result(FlutterError(code: "selection_failed", message: "selector command failed", details: nil))
            }
        case "urlTest":
            if let g = (call.arguments as? [String: Any])?["group"] as? String {
                queueURLTest(group: g)
            }
            result(nil)
        case "openVpnSettings":
            openSettings()
            result(nil)
        case "appGroupContainer":
            result(AuroraVPN.containerPath())
        case "readDiag":
            result(readDiag())
        case "lastDisconnectError":
            // Fetched on demand, not from the cache: Dart asks only after it has
            // observed this attempt's terminal status, and NE's answer at that
            // moment is authoritative. The cache is written by the observer for
            // the diagnostic log and can lose the race to this call.
            Task { @MainActor in
                guard #available(macOS 13.0, *),
                      let connection = (await self.loadManager())?.connection else {
                    result(self.lastDisconnectDetail)
                    return
                }
                connection.fetchLastDisconnectError { error in
                    let detail = error.map(AuroraDisconnectReason.describe)
                    DispatchQueue.main.async {
                        if let detail { self.lastDisconnectDetail = detail }
                        result(detail ?? self.lastDisconnectDetail)
                    }
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - control

    /// Ensure a VPN profile exists & is authorized. On macOS we FIRST make sure
    /// the PacketTunnel system extension is installed & approved (first run pops
    /// the "System Extension Blocked" prompt); then the first profile save
    /// triggers the "Allow VPN configuration" prompt. After a one-time approval
    /// both are silent.
    private func prepare() async throws -> Bool {
        guard SystemExtensionInstaller.isHostInstalled else {
            throw AuroraVPNError(SystemExtensionInstaller.installLocationMessage)
        }
        let extOk = await withCheckedContinuation { cont in
            SystemExtensionInstaller.shared.activate { cont.resume(returning: $0) }
        }
        if !extOk {
            // A Developer ID extension update must be notarized before macOS
            // replaces an already-approved version. Do not make a valid,
            // currently active PacketTunnel unusable merely because the
            // replacement is still awaiting notarization: an existing
            // non-invalid profile proves this Mac already has an approved
            // provider that can consume the newly compiled config.
            let existing = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            let hasUsableProfile = existing.contains { manager in
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return proto.providerBundleIdentifier == Self.providerBundleID &&
                    manager.connection.status != .invalid
            }
            guard hasUsableProfile else {
                throw AuroraVPNError("system extension not approved")
            }
            AuroraVPN.diag(
                "extension replacement unavailable; reusing approved installed provider"
            )
        }
        AuroraVPN.diag("extension ready; saving VPN preferences")
        do {
            let manager = try await configuredManager()
            try await Self.saveRetryingStale(manager, config: nil)
            try await manager.loadFromPreferences()
        } catch {
            let ns = error as NSError
            AuroraVPN.diag("saveToPreferences FAILED domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
            throw error
        }
        AuroraVPN.diag("prepare() OK")
        return true
    }

    private func start(_ configJson: String?) async throws {
        guard let configJson, !configJson.isEmpty else {
            throw AuroraVPNError("empty config from ConfigCompiler")
        }
        primeDesiredSelections(from: configJson)
        // Still write the file (harmless; used on iOS + by the CommandClient path),
        // but macOS's root system extension can't read our user container, so the
        // config is ALSO passed via providerConfiguration below.
        try writeConfig(configJson)
        AuroraVPN.diag("config written into App Group container (\(configJson.count) bytes)")
        let manager = try await configuredManager(config: configJson)
        try await Self.saveRetryingStale(manager, config: configJson)
        try await manager.loadFromPreferences()
        lastDisconnectDetail = nil
        try manager.connection.startVPNTunnel()
        AuroraVPN.diag("startVPNTunnel() issued")
    }

    /// Asks NE why `connection` ended. Best-effort and asynchronous: the Dart
    /// side reads `lastDisconnectDetail` only after it has itself observed the
    /// terminal status, by which time this has normally landed; a miss simply
    /// falls back to the extension log inference it used before.
    private func captureDisconnectReason(_ connection: NEVPNConnection) {
        guard #available(macOS 13.0, *) else { return }
        connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            let detail = AuroraDisconnectReason.describe(error)
            DispatchQueue.main.async {
                self?.lastDisconnectDetail = detail
                AuroraVPN.diag("NE last disconnect error: \(detail)")
            }
        }
    }

    private func stop() async {
        (await loadManager())?.connection.stopVPNTunnel()
        detachCommandClient()?.stop()
    }

    private func detachCommandClient() -> AuroraCommandClient? {
        commandStateLock.lock()
        let client = commandClient
        commandClient = nil
        commandStateLock.unlock()
        return client
    }

    /// Capture every selector's config default before NetworkExtension starts.
    /// A start-time select command normally arrives before CommandServer is
    /// reachable; retaining it here prevents that command from being silently
    /// discarded. It also gives every new connection a known-good selection
    /// instead of inheriting a previous connection's fail-closed state.
    private func primeDesiredSelections(from configJson: String) {
        var selections: [String: String] = [:]
        if let data = configJson.data(using: .utf8),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let outbounds = root["outbounds"] as? [[String: Any]] {
            for outbound in outbounds where outbound["type"] as? String == "selector" {
                guard let tag = outbound["tag"] as? String else { continue }
                let members = outbound["outbounds"] as? [String]
                if let selected = outbound["default"] as? String ?? members?.first {
                    selections[tag] = selected
                }
            }
        }
        commandStateLock.lock()
        desiredSelections = selections
        pendingURLTests.removeAll()
        commandStateLock.unlock()
        AuroraVPN.diag("primed \(selections.count) selector default(s)")
    }

    private func queueSelection(group: String, tag: String) throws {
        commandStateLock.lock()
        desiredSelections[group] = tag
        let client = commandClient
        commandStateLock.unlock()
        AuroraVPN.diag("queued selector \(group) -> \(tag)")
        try client?.select(group, tag)
    }

    private func queueURLTest(group: String) {
        commandStateLock.lock()
        pendingURLTests.insert(group)
        let client = commandClient
        commandStateLock.unlock()
        client?.urlTest(group)
    }

    private func replayQueuedCommands(on client: AuroraCommandClient) {
        commandStateLock.lock()
        let selections = desiredSelections
        let urlTests = pendingURLTests
        pendingURLTests.removeAll()
        commandStateLock.unlock()
        for (group, tag) in selections {
            try? client.select(group, tag)
        }
        for group in urlTests {
            client.urlTest(group)
        }
    }

    /// Loads the existing manager (or makes a new one) and applies our protocol.
    /// When `config` is supplied it is embedded in providerConfiguration so the
    /// root system extension receives it directly from NE (see start()).
    private func configuredManager(config: String? = nil) async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()
        cachedManager = manager
        Self.applyProtocol(manager, config: config)
        return manager
    }

    /// (Re)applies our tunnel protocol to `manager`. `config == nil` (prepare)
    /// must NOT wipe a previously saved providerConfiguration: the root
    /// extension re-reads it on every reassert, and an empty config there kills
    /// the tunnel instantly.
    private static func applyProtocol(_ manager: NETunnelProviderManager, config: String?) {
        let existing = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = displayName
        if let config {
            proto.providerConfiguration = [
                "config": config,
                "commandSecret": commandSecret,
            ]
        } else if var existing {
            existing["commandSecret"] = commandSecret
            proto.providerConfiguration = existing
        }
        manager.protocolConfiguration = proto
        manager.localizedDescription = displayName
        manager.isEnabled = true
    }

    /// saveToPreferences races with any concurrent NE preference writer (a
    /// parallel prepare/start Task, the system, another VPN app toggling): the
    /// manager's in-memory snapshot goes stale and NE fails with
    /// NEVPNErrorConfigurationStale ("configuration is stale"). The documented
    /// recovery is reload → reapply → save again, not surfacing the error.
    private static func saveRetryingStale(
        _ manager: NETunnelProviderManager,
        config: String?
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await manager.saveToPreferences()
                return
            } catch {
                let ns = error as NSError
                attempt += 1
                guard ns.domain == NEVPNErrorDomain,
                      ns.code == NEVPNError.Code.configurationStale.rawValue,
                      attempt < 3 else { throw error }
                diag("saveToPreferences stale (attempt \(attempt)); reloading and retrying")
                try await manager.loadFromPreferences()
                applyProtocol(manager, config: config)
            }
        }
    }

    private func currentStatusString() async -> String {
        guard let connection = (await loadManager())?.connection else { return "disconnected" }
        return Self.auroraStatus(connection.status)
    }

    private func writeConfig(_ json: String) throws {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw AuroraVPNError("App Group container unavailable: \(Self.appGroupID)")
        }
        let url = container.appendingPathComponent(Self.configFileName)
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    private func openSettings() {
        // macOS: open System Settings ▸ VPN pane.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    // MARK: - status stream + command client lifecycle

    private func attachStatus(_ sink: @escaping FlutterEventSink) {
        statusSink = sink
        if statusObserver == nil {
            statusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let conn = note.object as? NEVPNConnection else { return }
                // Every live NEVPNConnection instance in this process posts the
                // same session transition; forward each distinct VALUE once.
                let status = Self.auroraStatus(conn.status)
                guard status != self.lastPushedStatus else { return }
                self.lastPushedStatus = status
                if conn.status == .disconnected { self.captureDisconnectReason(conn) }
                self.statusSink?(status)
                self.onStatusChanged(conn.status)
            }
        }
        // Besides pushing the initial status to Flutter, also run it through
        // onStatusChanged: if the app starts while the tunnel is already up
        // (login item / reopened window) there is no status "change" event, so
        // without this the CommandClient never connects and stats and the node
        // list stay blank.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = (await self.loadManager())?.connection.status ?? .disconnected
            self.lastPushedStatus = Self.auroraStatus(status)
            sink(Self.auroraStatus(status))
            self.onStatusChanged(status)
        }
    }

    private func detachStatus() {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        statusObserver = nil
        statusSink = nil
    }

    private func onStatusChanged(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            if commandClient == nil {
                let client = AuroraCommandClient(
                    onStatus: { [weak self] m in
                        DispatchQueue.main.async {
                            self?.lastStats = m
                            self?.statsSink?(m)
                        }
                    },
                    onGroups: { [weak self] g in
                        DispatchQueue.main.async { self?.groupsSink?(g) }
                    })
                commandStateLock.lock()
                commandClient = client
                commandStateLock.unlock()
                client.start()
                replayQueuedCommands(on: client)
            }
        case .disconnected, .invalid:
            detachCommandClient()?.stop()
            lastStats = [:]
            statsSink?([
                "uplink": 0, "downlink": 0, "uplinkTotal": 0, "downlinkTotal": 0,
            ])
        default:
            break
        }
    }

    // MARK: - libbox setup (shared socket path with the extension)

    private static var didSetup = false
    static func libboxSetup() {
        guard !didSetup else { return }
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let working = container.appendingPathComponent("working").path
        let temp = container.appendingPathComponent("temp").path
        try? FileManager.default.createDirectory(atPath: working, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        let options = LibboxSetupOptions()
        options.basePath = container.path
        options.workingPath = working
        options.tempPath = temp
        options.logMaxLines = 100
        options.commandServerListenPort = commandPort
        options.commandServerSecret = commandSecret
        var error: NSError?
        LibboxSetup(options, &error)
        didSetup = true
    }

    static func containerPath() -> String? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?.path
    }

    // MARK: - helpers

    static func auroraStatus(_ status: NEVPNStatus) -> String {
        switch status {
        case .connecting, .reasserting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        case .disconnected, .invalid: return "disconnected"
        @unknown default: return "disconnected"
        }
    }

    /// Surfaces the App Group breadcrumb log + the extension's redirected stderr
    /// (debugging aid; not part of the Dart contract).
    private func readDiag() -> String {
        guard let c = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            return "NO App Group container"
        }
        let diag = (try? String(contentsOf: c.appendingPathComponent("diag.log"), encoding: .utf8)) ?? "(no diag.log)"
        let stderr = (try? String(contentsOf: c.appendingPathComponent("temp/stderr.log"), encoding: .utf8)) ?? "(no stderr.log)"
        let cfg = FileManager.default.fileExists(atPath: c.appendingPathComponent(Self.configFileName).path) ? "present" : "MISSING"
        return "config.json: \(cfg)\n\n=== diag.log ===\n\(diag)\n=== sing-box stderr ===\n\(stderr)"
    }

    static func diag(_ msg: String) {
        guard let c = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let line = "[app] \(msg)\n"
        let url = c.appendingPathComponent("diag.log")
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - NE disconnect reason

/// Turns NE's last-disconnect error into one line Dart can both show and match
/// on. The bracketed token is the stable part (`ConnectFlow._explainStartFailure`
/// keys on it); the domain/code and localized text are kept verbatim because a
/// user's screenshot is often the only evidence that reaches a remote debugger.
enum AuroraDisconnectReason {
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "ne_disconnect[\(token(domain: ns.domain, code: ns.code))] " +
            "(\(ns.domain) \(ns.code)): \(ns.localizedDescription)"
    }

    static func token(domain: String, code: Int) -> String {
        if #available(macOS 13.0, iOS 16.0, *), domain == NEVPNConnectionErrorDomain,
           let known = NEVPNConnectionError(rawValue: code) {
            switch known {
            case .noNetworkAvailable: return "no_network_available"
            case .unrecoverableNetworkChange: return "unrecoverable_network_change"
            case .configurationFailed: return "configuration_failed"
            case .serverNotResponding: return "server_not_responding"
            case .pluginFailed: return "plugin_failed"
            case .pluginDisabled: return "plugin_disabled"
            case .configurationNotFound: return "configuration_not_found"
            default: break
            }
        }
        let domainName = domain.split(separator: ".").last.map(String.init) ?? domain
        return "\(domainName.lowercased())_\(code)"
    }
}

// MARK: - generic EventChannel stream handler

final class AuroraStreamHandler: NSObject, FlutterStreamHandler {
    private let onListenCb: (@escaping FlutterEventSink) -> Void
    private let onCancelCb: () -> Void

    init(onListen: @escaping (@escaping FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
        onListenCb = onListen
        onCancelCb = onCancel
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListenCb(events)
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        onCancelCb()
        return nil
    }
}

// MARK: - libbox CommandClient (status / groups / actions)

/// Wraps a libbox `CommandClient` that connects to the PacketTunnel extension's
/// `CommandServer` over the shared App Group unix socket. Receives 1 Hz traffic
/// status + outbound-group snapshots and forwards them as plain maps for the
/// Flutter EventChannels. Auto-reconnects while the tunnel is up.
final class AuroraCommandClient: NSObject {
    private var client: LibboxCommandClient?
    private let onStatus: ([String: Any]) -> Void
    private let onGroups: ([[String: Any]]) -> Void
    private let stateLock = NSLock()
    private var stopped = true
    // Every transport has its own handler generation. The status and group
    // streams can both report one disconnect, and retired streams can report
    // it after their replacement is already healthy.
    private var connectionGeneration = 0
    private var serverReady = false
    private var desiredSelections: [String: String] = [:]
    private var pendingURLTests: Set<String> = []

    init(onStatus: @escaping ([String: Any]) -> Void,
         onGroups: @escaping ([[String: Any]]) -> Void) {
        self.onStatus = onStatus
        self.onGroups = onGroups
        super.init()
    }

    func start() {
        stateLock.lock()
        guard stopped else { stateLock.unlock(); return }
        stopped = false
        stateLock.unlock()
        scheduleConnect(after: 0)
    }

    func stop() {
        stateLock.lock()
        stopped = true
        serverReady = false
        connectionGeneration += 1
        let retired = client
        client = nil
        desiredSelections.removeAll()
        pendingURLTests.removeAll()
        stateLock.unlock()
        try? retired?.disconnect()
    }

    func select(_ group: String, _ tag: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        desiredSelections[group] = tag
        guard serverReady else { return }
        guard let client else { throw AuroraVPNError("command client unavailable") }
        try client.selectOutbound(group, outboundTag: tag)
    }

    private func applyDesiredSelection(_ group: String, _ tag: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard serverReady, desiredSelections[group] == tag, let client else { return }
        try? client.selectOutbound(group, outboundTag: tag)
    }

    func urlTest(_ group: String) {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        pendingURLTests.insert(group)
        guard serverReady, let connection = client else {
            stateLock.unlock()
            return
        }
        let generation = connectionGeneration
        stateLock.unlock()
        do {
            try connection.urlTest(group)
            stateLock.lock()
            if connectionGeneration == generation { pendingURLTests.remove(group) }
            stateLock.unlock()
        } catch {
            AuroraVPN.diag("urlTest \(group) failed: \(error.localizedDescription)")
        }
    }

    /// Claim a new generation before disconnecting the old client. Additional
    /// errors from its other stream then fail the generation check instead of
    /// spawning another dial that closes a healthy replacement transport.
    private func scheduleConnect(after delay: TimeInterval, failedGeneration: Int? = nil) {
        stateLock.lock()
        guard !stopped,
              failedGeneration == nil || failedGeneration == connectionGeneration else {
            stateLock.unlock()
            return
        }
        connectionGeneration += 1
        let generation = connectionGeneration
        serverReady = false
        let retired = client
        client = nil
        stateLock.unlock()
        try? retired?.disconnect()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connectLoop(generation)
        }
    }

    private func connectLoop(_ generation: Int) {
        stateLock.lock()
        guard !stopped, connectionGeneration == generation else {
            stateLock.unlock()
            return
        }
        let options = LibboxCommandClientOptions()
        options.statusInterval = Int64(NSEC_PER_SEC)
        options.addCommand(LibboxCommandStatus)
        options.addCommand(LibboxCommandGroup)
        let handler = AuroraCommandConnection(owner: self, generation: generation)
        let connection = LibboxNewCommandClient(handler, options)
        client = connection
        stateLock.unlock()
        do {
            guard let connection else { throw AuroraVPNError("command client unavailable") }
            try connection.connect()
            // stop() can run while libbox is dialing; close a late successful
            // connection too, so it cannot survive the session that owned it.
            if !accepts(generation) { try? connection.disconnect() }
        } catch {
            scheduleConnect(after: 0.5, failedGeneration: generation)
        }
    }

    fileprivate func accepts(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stopped && connectionGeneration == generation
    }

    fileprivate func connected(_ generation: Int) {
        stateLock.lock()
        guard !stopped, connectionGeneration == generation else {
            stateLock.unlock()
            return
        }
        serverReady = true
        let selections = desiredSelections
        let urlTests = pendingURLTests
        stateLock.unlock()
        DispatchQueue.global().async { [weak self] in
            guard let self, self.accepts(generation) else { return }
            for (group, tag) in selections {
                self.applyDesiredSelection(group, tag)
            }
            for group in urlTests { self.urlTest(group) }
        }
    }

    fileprivate func disconnected(_ generation: Int) {
        scheduleConnect(after: 1, failedGeneration: generation)
    }

    fileprivate func receiveGroups(_ groups: [[String: Any]], generation: Int) {
        if accepts(generation) { onGroups(groups) }
    }

    fileprivate func receiveStatus(_ status: [String: Any], generation: Int) {
        if accepts(generation) { onStatus(status) }
    }
}

/// libbox callbacks do not identify their connection. A handler per transport
/// supplies that identity, including for callbacks arriving after replacement.
private final class AuroraCommandConnection: NSObject, LibboxCommandClientHandlerProtocol {
    private weak var owner: AuroraCommandClient?
    private let generation: Int

    init(owner: AuroraCommandClient, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    func connected() { owner?.connected(generation) }
    func disconnected(_ message: String?) { owner?.disconnected(generation) }

    func clearLogs() {}

    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode _: String?) {}

    func setDefaultLogLevel(_: Int32) {}

    func updateClashMode(_: String?) {}

    // Swift imports `writeConnectionEvents:` as `write(_:)` (omit-needless-words,
    // since the param type LibboxConnectionEvents matches the method's suffix).
    func write(_: LibboxConnectionEvents?) {}

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        guard let message else { return }
        var groups: [[String: Any]] = []
        while message.hasNext() {
            guard let g = message.next() else { break }
            var items: [[String: Any]] = []
            if let it = g.getItems() {
                while it.hasNext() {
                    guard let item = it.next() else { break }
                    items.append([
                        "tag": item.tag,
                        "type": item.type,
                        "delay": Int(item.urlTestDelay),
                    ])
                }
            }
            groups.append([
                "tag": g.tag,
                "type": g.type,
                "selected": g.selected,
                "selectable": g.selectable,
                "items": items,
            ])
        }
        owner?.receiveGroups(groups, generation: generation)
    }

    func writeLogs(_: (any LibboxLogIteratorProtocol)?) {}

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let m = message else { return }
        owner?.receiveStatus([
            "uplink": Int(m.uplink),
            "downlink": Int(m.downlink),
            "uplinkTotal": Int(m.uplinkTotal),
            "downlinkTotal": Int(m.downlinkTotal),
        ], generation: generation)
    }
}

// MARK: - error

private struct AuroraVPNError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
