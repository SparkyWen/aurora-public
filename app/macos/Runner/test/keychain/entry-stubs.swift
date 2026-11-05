import Foundation
import FlutterMacOS
// Intercept the AppKit entry boundary as well, so a missing CLI dispatch is a
// deterministic test failure rather than creating a test GUI or hanging.
func NSApplicationMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    exit(77)
}
final class AuroraVPN {
    init(messenger: Any) { fatalError("VPN bridge must not start in maintenance") }
    static func installRuntimeConfig(_ config: String, shouldStart: Bool) async throws {
        fatalError("VPN configuration must not change in maintenance")
    }
    static func stopForTermination() async { fatalError("VPN must not stop in maintenance") }
}
final class SystemExtensionInstaller {
    static var shared: SystemExtensionInstaller { fatalError("extension must not activate in maintenance") }
    func activate(_ completion: (Bool) -> Void) { fatalError() }
    static func diag(_ message: String) { fatalError() }
}
func RegisterGeneratedPlugins(registry: FlutterViewController) {
    fatalError("plugins must not start in maintenance")
}
