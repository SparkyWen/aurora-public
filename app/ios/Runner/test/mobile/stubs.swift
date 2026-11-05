import Foundation

protocol FlutterBinaryMessenger {}
final class TestMessenger: FlutterBinaryMessenger {}
typealias FlutterResult = (Any?) -> Void
typealias FlutterEventSink = (Any?) -> Void
let FlutterMethodNotImplemented = "notImplemented"
final class FlutterError: NSObject {
    let code: String
    init(code: String, message: String?, details: Any?) { self.code = code }
}
final class FlutterMethodCall {
    let method: String
    let arguments: Any?
    init(_ method: String, _ arguments: Any?) { self.method = method; self.arguments = arguments }
}
final class FlutterMethodChannel {
    static var current: FlutterMethodChannel!
    var handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?
    init(name: String, binaryMessenger: FlutterBinaryMessenger) { Self.current = self }
    func setMethodCallHandler(_ handler: @escaping (FlutterMethodCall, @escaping FlutterResult) -> Void) { self.handler = handler }
}
protocol FlutterStreamHandler {
    func onListen(withArguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError?
    func onCancel(withArguments: Any?) -> FlutterError?
}
final class FlutterEventChannel {
    static var channels: [String: FlutterEventChannel] = [:]
    var handler: FlutterStreamHandler?
    init(name: String, binaryMessenger: FlutterBinaryMessenger) { Self.channels[name] = self }
    func setStreamHandler(_ handler: FlutterStreamHandler) { self.handler = handler }
}
enum NEVPNStatus { case invalid, disconnected, connecting, connected, reasserting, disconnecting }
class NEVPNProtocol: NSObject {}
final class NETunnelProviderProtocol: NEVPNProtocol {
    var providerBundleIdentifier: String?
    var serverAddress: String?
}
class NEVPNConnection: NSObject {
    var status: NEVPNStatus = .disconnected
    static var starts = 0
    static var stops = 0
    func startVPNTunnel() throws { Self.starts += 1 }
    func stopVPNTunnel() { Self.stops += 1; status = .disconnected }
    /// iOS 16+ API surface used by captureDisconnectReason; the double reports
    /// whatever a test injected here (nil = NE had no reason to give).
    var lastDisconnectError: Error?
    func fetchLastDisconnectError(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(lastDisconnectError)
    }
}
final class NETunnelProviderSession: NEVPNConnection {
    var sessionID = UUID().uuidString
    var snapshotStatus = "connected"
    var calls: [String] = []
    var onMessage: (([String: Any], @escaping (Data?) -> Void) -> Void)?
    func sendProviderMessage(_ data: Data, responseHandler: ((Data?) -> Void)?) throws {
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        calls.append(message["method"] as? String ?? "unknown")
        let callback = responseHandler ?? { _ in }
        if let onMessage { onMessage(message, callback); return }
        let reply: [String: Any] = message["method"] as? String == "sessionSnapshot"
            ? ["status": snapshotStatus, "sessionId": sessionID]
            : ["result": "reloaded"]
        callback(try! JSONSerialization.data(withJSONObject: reply))
    }
}
final class NETunnelProviderManager: NSObject {
    static var managers: [NETunnelProviderManager] = []
    static var saves = 0
    static var saveAction: (() async throws -> Void)?
    static var loadAction: (() async throws -> Void)?
    var connection: NEVPNConnection = NETunnelProviderSession()
    var protocolConfiguration: NEVPNProtocol?
    var localizedDescription: String?
    var isEnabled = false
    static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] { managers }
    static func loadAllFromPreferences(completionHandler: @escaping ([NETunnelProviderManager]?, Error?) -> Void) { completionHandler(managers, nil) }
    func saveToPreferences() async throws { Self.saves += 1; try await Self.saveAction?() }
    func loadFromPreferences() async throws { try await Self.loadAction?() }
}
let NEVPNErrorDomain = "NEVPNErrorDomain"
enum NEVPNError { enum Code: Int { case configurationStale = 1 } }
let NEVPNConnectionErrorDomain = "NEVPNConnectionErrorDomain"
/// Raw values mirror the SDK (verified against the real framework by
/// app/macos/Runner/test/disconnect_reason_main.swift).
enum NEVPNConnectionError: Int {
    case overslept = 1, noNetworkAvailable, unrecoverableNetworkChange, configurationFailed,
         serverAddressResolutionFailed, serverNotResponding, serverDead, authenticationFailed,
         clientCertificateInvalid, clientCertificateNotYetValid, clientCertificateExpired,
         pluginFailed, configurationNotFound, pluginDisabled, negotiationFailed,
         serverDisconnected, serverCertificateInvalid, serverCertificateNotYetValid,
         serverCertificateExpired
}
extension Notification.Name { static let NEVPNStatusDidChange = Notification.Name("TestNEStatusChanged") }
final class UIApplication {
    static let shared = UIApplication()
    static let openSettingsURLString = "app-settings:"
    func open(_ url: URL) {}
}
// The real Runner's filesystem calls are isolated from any App Group or device.
final class FileManager {
    static let `default` = FileManager()
    func containerURL(forSecurityApplicationGroupIdentifier: String) -> URL? { nil }
    func createDirectory(atPath: String, withIntermediateDirectories: Bool) throws {}
    func fileExists(atPath: String) -> Bool { false }
}
final class LibboxSetupOptions {
    var basePath = "", workingPath = "", tempPath = ""
    var logMaxLines: Int32 = 0
}
func LibboxSetup(_ options: LibboxSetupOptions, _ error: inout NSError?) {}

// Transport boundary only. The production AuroraVPN class is copied verbatim.
final class AuroraCommandClient {
    static var all: [AuroraCommandClient] = []
    var starts = 0
    var stops = 0
    var onStop: (() -> Void)?
    let onStatus: ([String: Any]) -> Void
    let onGroups: ([[String: Any]]) -> Void
    init(onStatus: @escaping ([String: Any]) -> Void, onGroups: @escaping ([[String: Any]]) -> Void) {
        self.onStatus = onStatus; self.onGroups = onGroups; Self.all.append(self)
    }
    func start() { starts += 1 }
    func stop() { stops += 1; onStop?() }
    func select(_ group: String, _ tag: String) throws {}
    func urlTest(_ group: String) {}
}
