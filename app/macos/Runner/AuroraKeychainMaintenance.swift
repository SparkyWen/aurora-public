import Cocoa
import NetworkExtension

struct AuroraKeychainCheckResult {
    let exitCode: Int32
    let message: String
}

struct AuroraKeychainDefaultACLCheck {
    static let option = "--qualify-keychain-default-acl"
    static func requested(_ arguments: [String]) -> Bool { arguments.dropFirst().contains { $0.hasPrefix(option) } }
    let api: AuroraKeychainAPI
    let qualify: () throws -> AuroraKeychainDefaultACLProvider
    func run(_ arguments: [String]) -> AuroraKeychainCheckResult {
        func refused(_ reason: String) -> AuroraKeychainCheckResult {
            .init(exitCode: 3, message: "KEYCHAIN_DEFAULT_ACL_REFUSED reason=\(reason)\n")
        }
        guard Array(arguments.dropFirst()) == [Self.option] else { return refused("arguments") }
        do {
            let defaults = try qualify()
            let counts = try AuroraKeychainMigration.checkAccessibility(api: api, defaults: defaults)
            guard counts.legacy + counts.background + counts.absent == 7 else { return refused("shape") }
            return .init(exitCode: 0, message: "KEYCHAIN_DEFAULT_ACL_QUALIFIED legacy=\(counts.legacy) background=\(counts.background) absent=\(counts.absent) dummy-roundtrip=passed cleanup=confirmed\n")
        } catch AuroraKeychainMigrationError.defaultACLCleanup {
            return refused("fixture-cleanup")
        } catch AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) {
            return .init(exitCode: 2, message: "KEYCHAIN_DEFAULT_ACL_LOCKED\n")
        } catch AuroraKeychainMigrationError.security(let status) {
            return refused("security status=\(status)")
        } catch AuroraKeychainMigrationError.observation(let reason) {
            return refused(reason.rawValue)
        } catch AuroraKeychainMigrationError.unknownAttributes {
            return refused("unknown-attributes")
        } catch AuroraKeychainMigrationError.receipt {
            return refused("fixture-journal")
        } catch {
            return refused("qualification")
        }
    }
}

struct AuroraKeychainReadOnlyCheck {
    static let option = "--check-keychain-accessibility"
    static func requested(_ arguments: [String]) -> Bool { arguments.dropFirst().contains { $0.hasPrefix(option) } }
    let api: AuroraKeychainAPI
    func run(_ arguments: [String]) -> AuroraKeychainCheckResult {
        func refused(_ reason: String) -> AuroraKeychainCheckResult {
            .init(exitCode: 3, message: "KEYCHAIN_ACCESSIBILITY_REFUSED reason=\(reason)\n")
        }
        guard Array(arguments.dropFirst()) == [Self.option] else { return refused("arguments") }
        do {
            let counts = try AuroraKeychainMigration.checkAccessibility(api: api)
            guard counts.legacy + counts.background + counts.absent == 7 else { return refused("shape") }
            return .init(exitCode: 0,
                         message: "KEYCHAIN_ACCESSIBILITY_COMPATIBLE legacy=\(counts.legacy) background=\(counts.background) absent=\(counts.absent)\n")
        } catch AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) {
            return .init(exitCode: 2, message: "KEYCHAIN_ACCESSIBILITY_LOCKED\n")
        } catch AuroraKeychainMigrationError.security(let status) {
            return .init(exitCode: 3, message: "KEYCHAIN_ACCESSIBILITY_REFUSED reason=security status=\(status)\n")
        } catch AuroraKeychainMigrationError.observation(let reason) {
            return refused(reason.rawValue)
        } catch AuroraKeychainMigrationError.qualificationRequired {
            return refused("qualification-required")
        } catch AuroraKeychainMigrationError.unknownAttributes(let schema) {
            guard !schema.isEmpty else { return refused("unexpected") }
            return .init(exitCode: 3,
                         message: "KEYCHAIN_ACCESSIBILITY_REFUSED reason=unknown-attributes schema=\(schema.map(\.rawValue).joined(separator: ","))\n")
        } catch {
            return refused("unexpected")
        }
    }
}

protocol AuroraKeychainMaintenanceEnvironment {
    func hasOtherGUI() -> Bool
    func tunnelsStopped() async throws -> Bool
    func performRollback(after admission: () async throws -> Void) async throws
}

struct AuroraKeychainMaintenance {
    static let option = "--rollback-keychain-accessibility"
    static func requested(_ arguments: [String]) -> Bool { arguments.dropFirst().contains { $0.hasPrefix(option) } }
    let environment: AuroraKeychainMaintenanceEnvironment
    func run(_ arguments: [String]) async throws {
        guard Array(arguments.dropFirst()) == [Self.option, "--confirm-aurora-stopped"] else {
            throw AuroraKeychainMigrationError.refused
        }
        try await environment.performRollback {
            guard !environment.hasOtherGUI() else { throw AuroraKeychainMigrationError.refused }
            // Hold the receipt lock across both fresh observations so a new
            // GUI cannot pass its migration barrier during maintenance.
            for _ in 0..<2 {
                guard try await environment.tunnelsStopped(), !environment.hasOtherGUI() else {
                    throw AuroraKeychainMigrationError.refused
                }
            }
        }
    }
}

struct AuroraSystemKeychainMaintenance: AuroraKeychainMaintenanceEnvironment {
    func hasOtherGUI() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.aurora.vpn" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    func tunnelsStopped() async throws -> Bool {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.allSatisfy {
            guard let proto = $0.protocolConfiguration as? NETunnelProviderProtocol,
                  proto.providerBundleIdentifier == "com.aurora.vpn.PacketTunnel" else { return true }
            return $0.connection.status == .disconnected || $0.connection.status == .invalid
        }
    }

    func performRollback(after admission: () async throws -> Void) async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let receipts = AuroraKeychainFileReceiptStore(
            directory: support.appendingPathComponent("Aurora-KeychainMigration", isDirectory: true))
        try await AuroraKeychainMigration(api: AuroraSystemKeychainAPI(), receipts: receipts,
                                         defaults: AuroraSystemDefaultACLFactory.provider)
            .rollback(afterChecking: admission)
    }
}
