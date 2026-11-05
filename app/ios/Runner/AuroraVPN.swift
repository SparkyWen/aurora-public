import Flutter
import Foundation
import Libbox
import NetworkExtension
import UIKit

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

    /// NE's own verdict on why the last session ended (see the macOS Runner's
    /// note of the same name): captured on `.disconnected`, cleared per start,
    /// read by Dart through `lastDisconnectError` after a failed start.
    private var lastDisconnectDetail: String?

    private var commandClient: AuroraCommandClient?
    private var lastStats: [String: Any] = [:]
    // Main-thread control identity, independent of delayed NE/provider replies.
    private var ownedManager: NETunnelProviderManager?
    private var controlIntent = 0
    private var reloadOperation: UUID?
    private var mobileReplies: [UUID: () -> Void] = [:]
    private var telemetryGeneration = 0
    private var blockedTelemetrySessionID: String?

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
        // FlutterResult must be delivered on the platform (main) thread; a bare
        // Task runs on the concurrent executor and the darwin embedder can drop
        // the reply on exactly the calls the Dart connect pipeline awaits.
        switch call.method {
        case "prepare":
            let intent = beginControlIntent()
            Task { @MainActor in
                do { result(try await self.prepare(intent: intent)) }
                catch { result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil)) }
            }
        case "start":
            let config = (call.arguments as? [String: Any])?["config"] as? String
            let intent = beginControlIntent()
            Task { @MainActor in
                do {
                    try await self.start(config, intent: intent)
                    result(nil)
                } catch {
                    AuroraVPN.diag("start ERROR: \(error.localizedDescription)")
                    result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
                }
            }
        case "stop":
            let intent = beginControlIntent()
            let retired = retireTelemetry()
            DispatchQueue.global().async { retired?.stop() }
            Task { @MainActor in await self.stop(intent: intent); result(nil) }
        case "status":
            Task { @MainActor in result(await self.currentStatusString()) }
        case "sessionSnapshot":
            Task { @MainActor in result(await self.mobileSessionSnapshot()) }
        case "reloadCurrentSession":
            let sessionID = (call.arguments as? [String: Any])?["sessionId"] as? String
            Task { @MainActor in result(await self.reloadCurrentSession(sessionID)) }
        case "queryStats":
            result(lastStats)
        case "lastDisconnectError":
            // On demand rather than cached: see the macOS Runner's note.
            Task { @MainActor in
                guard #available(iOS 16.0, *),
                      let connection = self.ownedManager?.connection else {
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
        case "selectOutbound":
            let args = call.arguments as? [String: Any]
            guard let g = args?["group"] as? String, !g.isEmpty,
                  let t = args?["tag"] as? String, !t.isEmpty else {
                result(FlutterError(code: "invalid_selection", message: "selector arguments are required", details: nil))
                return
            }
            guard let commandClient else {
                // A freshly compiled selector defaults to fail-closed; Dart
                // still waits for group-stream readback before accepting this.
                if t == "fail-closed" { result(nil) }
                else { result(FlutterError(code: "command_unavailable", message: "selector unavailable", details: nil)) }
                return
            }
            do {
                try commandClient.select(g, t)
                result(nil)
            } catch {
                result(FlutterError(code: "selection_failed", message: "selector command failed", details: nil))
            }
        case "urlTest":
            if let g = (call.arguments as? [String: Any])?["group"] as? String {
                commandClient?.urlTest(g)
            }
            result(nil)
        case "openVpnSettings":
            openSettings()
            result(nil)
        case "appGroupContainer":
            result(AuroraVPN.containerPath())
        case "readDiag":
            result(readDiag())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - control

    /// Ensure a VPN profile exists & is authorized. First save triggers the
    /// system "Allow VPN configuration" prompt.
    @MainActor private func prepare(intent: Int) async throws -> Bool {
        let manager = try await configuredManager(intent: intent)
        try await saveRetryingStale(manager, intent: intent)
        try requireCurrentIntent(intent)
        try await manager.loadFromPreferences()
        try requireCurrentIntent(intent)
        return true
    }

    @MainActor private func start(_ configJson: String?, intent: Int) async throws {
        try requireCurrentIntent(intent)
        guard let configJson, !configJson.isEmpty else {
            throw AuroraVPNError("empty config from ConfigCompiler")
        }
        try writeConfig(configJson)
        AuroraVPN.diag("config written into App Group container (\(configJson.count) bytes)")
        let manager = try await configuredManager(intent: intent)
        try await saveRetryingStale(manager, intent: intent)
        try requireCurrentIntent(intent)
        try await manager.loadFromPreferences()
        try requireCurrentIntent(intent)
        lastDisconnectDetail = nil
        try manager.connection.startVPNTunnel()
        AuroraVPN.diag("startVPNTunnel() issued")
    }

    private func captureDisconnectReason(_ connection: NEVPNConnection) {
        guard #available(iOS 16.0, *) else { return }
        connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            let detail = AuroraDisconnectReason.describe(error)
            DispatchQueue.main.async {
                self?.lastDisconnectDetail = detail
                AuroraVPN.diag("NE last disconnect error: \(detail)")
            }
        }
    }

    @MainActor private func stop(intent: Int) async {
        let manager: NETunnelProviderManager?
        if let ownedManager { manager = ownedManager }
        else { manager = Self.onlyOwnManager((try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []) }
        guard controlIntent == intent else { return }
        manager?.connection.stopVPNTunnel()
    }

    /// Loads the existing manager (or makes a new one) and applies our protocol.
    @MainActor private func configuredManager(intent: Int) async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        try requireCurrentIntent(intent)
        let own = managers.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID }
        guard own.count <= 1 else { throw AuroraVPNError("multiple Aurora VPN configurations") }
        let manager = own.first ?? NETunnelProviderManager()
        Self.applyProtocol(manager)
        ownedManager = manager
        return manager
    }

    private static func onlyOwnManager(_ managers: [NETunnelProviderManager]) -> NETunnelProviderManager? {
        let own = managers.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID }
        return own.count == 1 ? own[0] : nil
    }

    private func requireCurrentIntent(_ intent: Int) throws {
        guard controlIntent == intent else { throw AuroraVPNError("connection request cancelled") }
    }

    private func beginControlIntent() -> Int {
        controlIntent += 1
        reloadOperation = nil
        blockedTelemetrySessionID = nil
        cancelMobileReplies()
        return controlIntent
    }

    private func cancelMobileReplies() {
        let cancelled = Array(mobileReplies.values)
        mobileReplies.removeAll()
        for cancel in cancelled { cancel() }
    }

    private static func applyProtocol(_ manager: NETunnelProviderManager) {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = displayName
        manager.protocolConfiguration = proto
        manager.localizedDescription = displayName
        manager.isEnabled = true
    }

    /// saveToPreferences races with any concurrent NE preference writer (a
    /// parallel prepare/start Task, the system): the manager's in-memory
    /// snapshot goes stale and NE fails with NEVPNErrorConfigurationStale
    /// ("configuration is stale"). The documented recovery is reload → reapply
    /// → save again, not surfacing the error (same fix as macOS AuroraVPN).
    @MainActor private func saveRetryingStale(_ manager: NETunnelProviderManager, intent: Int) async throws {
        var attempt = 0
        while true {
            try requireCurrentIntent(intent)
            do {
                try await manager.saveToPreferences()
                return
            } catch {
                let ns = error as NSError
                attempt += 1
                guard ns.domain == NEVPNErrorDomain,
                      ns.code == NEVPNError.Code.configurationStale.rawValue,
                      attempt < 3 else { throw error }
                Self.diag("saveToPreferences stale (attempt \(attempt)); reloading and retrying")
                try await manager.loadFromPreferences()
                try requireCurrentIntent(intent)
                Self.applyProtocol(manager)
            }
        }
    }

    @MainActor private func currentStatusString() async -> String {
        if let ownedManager { return Self.auroraStatus(ownedManager.connection.status) }
        let intent = controlIntent
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard controlIntent == intent, let manager = Self.onlyOwnManager(managers) else { return "disconnected" }
        ownedManager = manager
        let connection = manager.connection
        return Self.auroraStatus(connection.status)
    }

    // MARK: - mobile recovery inside an existing system VPN session

    /// One deadline owns each reply. Cancellation/timeout does not claim that
    /// work already accepted by the extension has stopped.
    @MainActor private func mobileReply<Value>(until deadline: TimeInterval,
        operation: (@escaping (Value?) -> Void) -> Void) async -> Value? {
        guard deadline > ProcessInfo.processInfo.systemUptime else { return nil }
        let request = UUID()
        return await withCheckedContinuation { continuation in
            var completed = false
            var timeout: DispatchWorkItem?
            let finish: (Value?) -> Void = { [weak self] value in
                guard !completed else { return }
                completed = true
                timeout?.cancel()
                timeout = nil
                self?.mobileReplies.removeValue(forKey: request)
                continuation.resume(returning: value)
            }
            mobileReplies[request] = { finish(nil) }
            let timeoutWork = DispatchWorkItem { finish(nil) }
            timeout = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: timeoutWork)
            operation { value in DispatchQueue.main.async { finish(value) } }
        }
    }

    @MainActor private func loadedMobileSession(until deadline: TimeInterval, intent: Int) async -> NETunnelProviderSession? {
        if ownedManager == nil {
            let managers: [NETunnelProviderManager]? = await mobileReply(until: deadline) { finish in
                NETunnelProviderManager.loadAllFromPreferences { managers, error in finish(error == nil ? managers : nil) }
            }
            guard controlIntent == intent, let managers else { return nil }
            ownedManager = Self.onlyOwnManager(managers)
        }
        guard controlIntent == intent, let manager = ownedManager,
              (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID,
              manager.connection.status == .connected else { return nil }
        return manager.connection as? NETunnelProviderSession
    }

    private func isCurrentSession(_ session: NETunnelProviderSession, intent: Int) -> Bool {
        controlIntent == intent && ownedManager?.connection === session && session.status == .connected
    }

    @MainActor private func providerMessage(_ message: [String: Any], session: NETunnelProviderSession,
        intent: Int, until deadline: TimeInterval) async -> [String: Any]? {
        guard isCurrentSession(session, intent: intent),
              let payload = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        let data: Data? = await mobileReply(until: deadline) { finish in
            do { try session.sendProviderMessage(payload) { finish($0) } }
            catch { finish(nil) }
        }
        guard isCurrentSession(session, intent: intent), let data, data.count <= 4096 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func snapshotID(_ snapshot: [String: Any]?) -> String? {
        guard let id = snapshot?["sessionId"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id
    }

    @MainActor private func mobileSessionSnapshot() async -> [String: Any] {
        let intent = controlIntent
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard let session = await loadedMobileSession(until: deadline, intent: intent) else {
            return ["status": ownedManager.map { Self.auroraStatus($0.connection.status) } ?? "disconnected", "sessionId": NSNull()]
        }
        let snapshot = await providerMessage(["method": "sessionSnapshot"], session: session, intent: intent, until: deadline)
        guard isCurrentSession(session, intent: intent), let status = snapshot?["status"] as? String,
              ["connected", "connecting"].contains(status), let id = snapshotID(snapshot) else {
            return ["status": Self.auroraStatus(session.status), "sessionId": NSNull()]
        }
        return ["status": status, "sessionId": id]
    }

    @MainActor private func reloadCurrentSession(_ expectedID: String?) async -> String {
        guard reloadOperation == nil, let expectedID, UUID(uuidString: expectedID) != nil else { return "unavailable" }
        let operation = UUID(), intent = controlIntent
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        reloadOperation = operation
        defer { if reloadOperation == operation { reloadOperation = nil } }
        guard let session = await loadedMobileSession(until: min(deadline, ProcessInfo.processInfo.systemUptime + 3), intent: intent) else { return "unavailable" }
        let before = await providerMessage(["method": "sessionSnapshot"], session: session, intent: intent, until: min(deadline, ProcessInfo.processInfo.systemUptime + 3))
        guard reloadOperation == operation, before?["status"] as? String == "connected", snapshotID(before) == expectedID,
              isCurrentSession(session, intent: intent) else { return "unavailable" }
        blockedTelemetrySessionID = expectedID
        let retired = retireTelemetry()
        if let retired {
            let stopped: Bool? = await mobileReply(until: min(deadline, ProcessInfo.processInfo.systemUptime + 3)) { finish in
                DispatchQueue.global().async { retired.stop(); finish(true) }
            }
            guard stopped == true, reloadOperation == operation, isCurrentSession(session, intent: intent) else { return "requiresReconnect" }
        }
        // Reserve a final snapshot budget. NE can stay connected while the
        // extension is still retiring its old core after our RPC times out.
        let reply = await providerMessage(["method": "reloadCurrentSession", "sessionId": expectedID], session: session, intent: intent, until: deadline - 3)
        guard reloadOperation == operation, controlIntent == intent else { return "unavailable" }
        guard isCurrentSession(session, intent: intent) else { return "requiresReconnect" }
        let after = await providerMessage(["method": "sessionSnapshot"], session: session, intent: intent, until: deadline)
        guard reloadOperation == operation, isCurrentSession(session, intent: intent),
              after?["status"] as? String == "connected", snapshotID(after) == expectedID else { return "requiresReconnect" }
        let outcome = reply?["result"] as? String
        if outcome == "reloaded" || reply == nil {
            blockedTelemetrySessionID = nil
            startTelemetry()
        }
        return outcome == "reloaded" ? "reloaded" : (outcome == "unavailable" ? "unavailable" : "requiresReconnect")
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
        // iOS exposes no public deep link to the VPN pane; the app's Settings
        // page is the closest reachable entry (user then taps General → VPN).
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }

    // MARK: - status stream + command client lifecycle

    private func attachStatus(_ sink: @escaping FlutterEventSink) {
        statusSink = sink
        if statusObserver == nil {
            statusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let conn = note.object as? NEVPNConnection,
                      self.ownedManager?.connection === conn else { return }
                if conn.status == .disconnected { self.captureDisconnectReason(conn) }
                self.statusSink?(Self.auroraStatus(conn.status))
                self.onStatusChanged(conn.status)
            }
        }
        // Push the live status AND drive onStatusChanged: when the app cold-
        // launches while the tunnel is already connected (relaunch adopting a
        // running session) there is no NEVPNStatus "change" event, so without
        // this the CommandClient never connects and stats/node list stay blank.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let intent = self.controlIntent
            if self.ownedManager == nil {
                let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
                guard self.controlIntent == intent else { return }
                self.ownedManager = Self.onlyOwnManager(managers)
            }
            let status = self.ownedManager?.connection.status ?? .disconnected
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
            // NE can remain connected throughout a core reload or its failed
            // cleanup. Only the checked provider reply may reopen telemetry.
            guard reloadOperation == nil, blockedTelemetrySessionID == nil else { return }
            startTelemetry()
        case .disconnected, .invalid:
            // Native failure may disconnect before its RPC reply. Wake the
            // caller, but preserve its intent so it can report requiresReconnect.
            // An explicit prepare/start/stop cancels that intent separately.
            cancelMobileReplies()
            let retired = retireTelemetry()
            DispatchQueue.global().async { retired?.stop() }
        default:
            break
        }
    }

    private func retireTelemetry() -> AuroraCommandClient? {
        telemetryGeneration += 1
        let retired = commandClient
        commandClient = nil
        lastStats = [:]
        statsSink?(["uplink": 0, "downlink": 0, "uplinkTotal": 0, "downlinkTotal": 0])
        groupsSink?([[String: Any]]())
        return retired
    }

    private func startTelemetry() {
        guard commandClient == nil else { return }
        telemetryGeneration += 1
        let generation = telemetryGeneration
        let client = AuroraCommandClient(
            onStatus: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.telemetryGeneration == generation,
                          self.commandClient != nil, self.blockedTelemetrySessionID == nil else { return }
                    self.lastStats = message
                    self.statsSink?(message)
                }
            },
            onGroups: { [weak self] groups in
                DispatchQueue.main.async {
                    guard let self, self.telemetryGeneration == generation,
                          self.commandClient != nil, self.blockedTelemetrySessionID == nil else { return }
                    self.groupsSink?(groups)
                }
            })
        commandClient = client
        client.start()
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

/// Same contract as the macOS Runner: a stable bracketed token Dart matches on,
/// plus NE's domain/code and localized text verbatim.
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
// stateLock protects all mutable transport/lifecycle state. Immutable callbacks
// enqueue onto Runner's main queue; libbox synchronizes its own transport access.
final class AuroraCommandClient: NSObject, @unchecked Sendable {
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
