import Foundation
import Darwin

// Only external boundaries are doubled; both provider classes and health policy
// are compiled from their production files by run.sh.
struct HarnessError: LocalizedError {
    var errorDescription: String? { "injected startup failure" }
}
struct AuroraError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
final class Harness {
    static var servers: [LibboxCommandServer] = []
    static var platforms: [AuroraPlatform] = []
    static var failSetup = false
    static var failAllocation = false
    static var failListener = false
    static var failCore = false
    static var failCloseService = false
    static var blockFirstClose = false
    static var blockReload = false
    static var blockServerCreation = false
    static let serverCreationEntered = DispatchSemaphore(value: 0)
    static let releaseServerCreation = DispatchSemaphore(value: 0)
    static var failReload = false
    static let reloadEntered = DispatchSemaphore(value: 0)
    static let releaseReload = DispatchSemaphore(value: 0)
    static var cancelledTunnels = 0
    static var tunnelSettingsChanges = 0
    static var beforeServiceClose: (() -> Void)?
    static var resets = 0
    static var messages: [String] = []
    static let blockedClose = DispatchSemaphore(value: 0)
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AURORA_TEST_DIR"]!)
}
func extDiag(_ message: String) { Harness.messages.append(message) }
// An extension's process exit is an observable boundary, never exit the test.
func exit(_ code: Int32) {}
final class TestFileManager {
    static let `default` = TestFileManager()
    func containerURL(forSecurityApplicationGroupIdentifier _: String) -> URL? { Harness.directory }
    func createDirectory(atPath path: String, withIntermediateDirectories value: Bool) throws {
        try Foundation.FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: value)
    }
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try Foundation.FileManager.default.attributesOfItem(atPath: path)
    }
    func removeItem(atPath path: String) throws { try Foundation.FileManager.default.removeItem(atPath: path) }
    func moveItem(atPath a: String, toPath b: String) throws { try Foundation.FileManager.default.moveItem(atPath: a, toPath: b) }
    func fileExists(atPath path: String) -> Bool { Foundation.FileManager.default.fileExists(atPath: path) }
    @discardableResult func createFile(atPath path: String, contents: Data?, attributes: [FileAttributeKey: Any]) -> Bool {
        Foundation.FileManager.default.createFile(atPath: path, contents: contents, attributes: attributes)
    }
}
class NEPacketTunnelProvider {
    var protocolConfiguration: Any = NETunnelProviderProtocol()
    var reasserting = false
    func startTunnel(options: [String: NSObject]?) async throws {}
    func stopTunnel(with reason: NEProviderStopReason) async {}
    func sleep() async {}
    func wake() {}
    func handleAppMessage(_ data: Data, completionHandler: ((Data?) -> Void)? = nil) { completionHandler?(nil) }
    func cancelTunnelWithError(_ error: Error?) { Harness.cancelledTunnels += 1 }
    func setTunnelNetworkSettings(_ settings: Any?, completionHandler: @escaping (Error?) -> Void) {
        Harness.tunnelSettingsChanges += 1
        completionHandler(nil)
    }
}
enum NEProviderStopReason: Int { case userInitiated = 1 }
final class NETunnelProviderProtocol {
    var providerConfiguration: [String: Any]? = ["config": "{\"inbounds\":[]}", "commandSecret": "test-only"]
}
final class LibboxNotification {
    var identifier = "tailscale-authentication", typeID: Int32 = 10, openURL = ""
}
final class AuroraPlatform {
    weak var provider: PacketTunnelProvider?
    let sessionID: String
    let tailnetNotification: ((LibboxNotification) -> Void)?
    var networkSettings: Any? = NSObject()
    init(provider: PacketTunnelProvider, sessionID: String = "", safeLogs: Bool = false, tailnetNotification: ((LibboxNotification) -> Void)? = nil) {
        self.provider = provider
        self.sessionID = sessionID
        self.tailnetNotification = tailnetNotification
        Harness.platforms.append(self)
    }
    func reset() { Harness.resets += 1 }
}
final class LibboxSetupOptions {
    var basePath = "", workingPath = "", tempPath = "", commandServerSecret = ""
    var logMaxLines = 0, commandServerListenPort = 0
}
final class LibboxOverrideOptions {}
func LibboxSetup(_ options: LibboxSetupOptions, _ error: inout NSError?) {
    if Harness.failSetup { error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "PUBLIC_AUTH_ERROR_MARKER"]) }
}
func LibboxRedirectStderr(_ path: String, _ error: inout NSError?) {}
func LibboxSetMemoryLimit(_ enabled: Bool) {}
func LibboxNewCommandServer(_ handler: AuroraPlatform, _ platform: AuroraPlatform, _ error: inout NSError?) -> LibboxCommandServer? {
    if Harness.failAllocation {
        error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "PUBLIC_AUTH_ERROR_MARKER"])
        return nil
    }
    let server = LibboxCommandServer(index: Harness.servers.count)
    Harness.servers.append(server)
    if Harness.blockServerCreation {
        Harness.serverCreationEntered.signal()
        Harness.releaseServerCreation.wait()
    }
    return server
}
final class LibboxCommandServer {
    let index: Int
    var closeCalls = 0, closeServiceCalls = 0, coreStarts = 0
    var configs: [String] = []
    init(index: Int) { self.index = index }
    func start() throws { if Harness.failListener { throw HarnessError() } }
    func startOrReloadService(_ config: String, options: LibboxOverrideOptions) throws {
        coreStarts += 1
        configs.append(config)
        if coreStarts > 1 {
            Harness.reloadEntered.signal()
            if Harness.blockReload { Harness.releaseReload.wait() }
            if Harness.failReload { throw HarnessError() }
        }
        if Harness.failCore { throw HarnessError() }
    }
    func closeService() throws {
        closeServiceCalls += 1
        Harness.beforeServiceClose?()
        if Harness.failCloseService { throw HarnessError() }
        if index == 0 && Harness.blockFirstClose { Harness.blockedClose.wait() }
    }
    func close() { closeCalls += 1 }
    func writeMessage(_ level: Int, message: String) {}
    func pause() {}
    func wake() {}
}
