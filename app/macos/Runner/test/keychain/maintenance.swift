import Foundation

struct MaintenanceFailure: Error {}
final class MaintenanceEnvironment: AuroraKeychainMaintenanceEnvironment {
    var lockHeld = false
    var guiChecks = 0
    var tunnelChecks = 0
    var rollbacks = 0
    var guiAppearsAt: Int?
    var tunnelActiveAt: Int?
    var readError = false
    var rollbackError = false
    func hasOtherGUI() -> Bool { guiChecks += 1; return !lockHeld || guiAppearsAt == guiChecks }
    func tunnelsStopped() async throws -> Bool {
        tunnelChecks += 1
        if readError { throw MaintenanceFailure() }
        await Task.yield()
        return tunnelActiveAt != tunnelChecks
    }
    func performRollback(after admission: () async throws -> Void) async throws {
        lockHeld = true; defer { lockHeld = false }
        try await admission()
        try rollback()
    }
    func rollback() throws {
        rollbacks += 1
        if rollbackError { throw MaintenanceFailure() }
    }
}
struct EmptyKeychain: AuroraKeychainAPI {
    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]] { [] }
    func update(_ query: [String: Any], attributes: [String: Any]) throws { throw MaintenanceFailure() }
}
struct NoDefaultACLs: AuroraKeychainDefaultACLProvider {
    func prepare(accessibility: String) throws {}
    func matches(_ control: CFTypeRef, accessibility: String, group: String) throws -> Bool { false }
}
@main struct Tests {
    static func main() async {
        var passed = 0, failed = 0
        let valid = ["/fixture/aurora", "--rollback-keychain-accessibility", "--confirm-aurora-stopped"]
        for scenario in ["success", "missing-confirmation", "extra-argument", "duplicate-option",
                         "live-GUI", "late-GUI", "live-tunnel", "late-tunnel", "preferences-error", "rollback-error"] {
            let env = MaintenanceEnvironment()
            var args = valid
            switch scenario {
            case "missing-confirmation": args.removeLast()
            case "extra-argument": args.append("--start-vpn")
            case "duplicate-option": args.append("--rollback-keychain-accessibility")
            case "live-GUI": env.guiAppearsAt = 1
            case "late-GUI": env.guiAppearsAt = 2
            case "live-tunnel": env.tunnelActiveAt = 1
            case "late-tunnel": env.tunnelActiveAt = 2
            case "preferences-error": env.readError = true
            case "rollback-error": env.rollbackError = true
            default: break
            }
            var success = false
            do { try await AuroraKeychainMaintenance(environment: env).run(args); success = true }
            catch {}
            let okay = success == (scenario == "success") &&
                env.rollbacks == (["success", "rollback-error"].contains(scenario) ? 1 : 0)
            if okay { passed += 1; print("PASS maintenance \(scenario)") }
            else { failed += 1; print("FAIL maintenance \(scenario)") }
        }
        // This uses the real migration + real receipt store, rather than the
        // admission double above, to catch a missing lock across suspension.
        for reject in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let receipts = AuroraKeychainFileReceiptStore(directory: directory)
            let competing = AuroraKeychainFileReceiptStore(directory: directory)
            var baselineCalls = 0
            let migration = AuroraKeychainMigration(api: EmptyKeychain(), receipts: receipts, defaults: {
                baselineCalls += 1; return NoDefaultACLs()
            })
            do {
                try migration.prepare()
                var observed = false
                var rejected = false
                do {
                    try await migration.rollback(afterChecking: {
                        var competingAcquired = false
                        do { try competing.lock(); competingAcquired = true; competing.unlock() } catch {}
                        if competingAcquired { throw MaintenanceFailure() }
                        await Task.yield()
                        observed = true
                        if reject { throw MaintenanceFailure() }
                    })
                } catch { rejected = true }
                guard observed, rejected == reject, baselineCalls == (reject ? 1 : 2) else { throw MaintenanceFailure() }
                try competing.lock(); competing.unlock()
                passed += 1; print("PASS real receipt lock spans async admission; rejected=\(reject)")
            } catch { failed += 1; print("FAIL real receipt lock spans async admission") }
        }
        print("Maintenance gate: \(passed) passed, \(failed) failed (environment double; no device actions)")
        exit(failed == 0 ? 0 : 1)
    }
}
