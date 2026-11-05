import Foundation
import SystemExtensions

/// Activates the PacketTunnel system extension. First run triggers the macOS
/// "System Extension Blocked — Allow in System Settings" prompt; after the user
/// approves once, subsequent launches are silent.
final class SystemExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionInstaller()
    static let extensionBundleID = "com.aurora.vpn.PacketTunnel"

    /// A system extension can only be activated by a host app installed under
    /// /Applications. Running Flutter's raw build product used to surface an
    /// opaque PlatformException(OSSystemExtensionErrorDomain code=3).
    static var isHostInstalled: Bool {
        let bundlePath = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return bundlePath == "/Applications" || bundlePath.hasPrefix("/Applications/")
    }

    static var installLocationMessage: String {
        "This Aurora is a build-directory copy and cannot activate the macOS VPN system extension. " +
        "Open only /Applications/aurora.app; run app/macos/install_release.sh to install it correctly."
    }

    // Breadcrumbs to the App Group diag.log — the app's NSLog is suppressed under
    // sandbox, so this is how we surface the real OSSystemExtension error.
    static func diag(_ msg: String) {
        guard let c = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.aurora.vpn") else { return }
        let line = "[sysext] \(msg)\n"
        let url = c.appendingPathComponent("diag.log")
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile(); h.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // Multiple callers can await one in-flight request (launch auto-activate +
    // the user's connect click may race); all queued completions get the result.
    private var completions: [(Bool) -> Void] = []
    private var inFlight = false

    func activate(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard Self.isHostInstalled else {
                Self.diag("activation refused: \(Self.installLocationMessage) bundle=\(Bundle.main.bundlePath)")
                completion(false)
                return
            }
            self.completions.append(completion)
            guard !self.inFlight else {
                Self.diag("activate() joined in-flight request")
                return
            }
            self.inFlight = true
            Self.diag("activate() requesting \(Self.extensionBundleID); bundle=\(Bundle.main.bundlePath)")
            let req = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: Self.extensionBundleID,
                queue: .main)
            req.delegate = self
            OSSystemExtensionManager.shared.submitRequest(req)
            Self.diag("submitRequest returned (async pending)")
        }
    }

    private func finish(_ ok: Bool) {
        inFlight = false
        let cbs = completions
        completions = []
        cbs.forEach { $0(ok) }
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Self.diag("requestNeedsUserApproval — go approve in System Settings")
        NSLog("[aurora] system extension needs user approval in System Settings")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Self.diag("didFinishWithResult: \(result.rawValue) (0=completed,1=willCompleteAfterReboot)")
        finish(result == .completed)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        Self.diag("didFailWithError domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
        NSLog("[aurora] system extension activation failed: %@", error.localizedDescription)
        finish(false)
    }
}
