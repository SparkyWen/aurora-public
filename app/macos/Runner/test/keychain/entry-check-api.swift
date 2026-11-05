// The production AppDelegate, CLI policy and observation code are unchanged.
// Substitute only the real user's Security adapter for subprocess checks.
import Foundation
import Security
final class AuroraSystemKeychainAPI: AuroraKeychainAPI {
    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]] {
        switch ProcessInfo.processInfo.environment["AURORA_KEYCHAIN_ENTRY_FIXTURE"] {
        case "no-query": exit(78)
        case "locked": throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed)
        case "refused": throw AuroraKeychainMigrationError.security(errSecMissingEntitlement)
        case "result-type": throw AuroraKeychainMigrationError.observation(.resultType)
        default: break
        }
        guard query[kSecReturnData as String] == nil, query[kSecValueData as String] == nil,
              let key = query[kSecAttrAccount as String] as? String,
              AuroraKeychainMigration.keys.contains(key) else { exit(79) }
        var row: [String: Any] = [kSecAttrAccount as String: key,
                 kSecAttrService as String: "flutter_secure_storage_service",
                 kSecAttrSynchronizable as String: false,
                 kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                 kSecAttrAccessGroup as String: "fixture.group"]
        switch ProcessInfo.processInfo.environment["AURORA_KEYCHAIN_ENTRY_FIXTURE"] {
        case "duplicate": return [row, row]
        case "unknown-schema":
            row[kSecAttrGeneric as String] = Data("PRIVATE_VALUE".utf8)
            row["PRIVATE_UNKNOWN_KEY"] = "PRIVATE_VALUE"
        default: break
        }
        return [row]
    }
    func update(_ query: [String: Any], attributes: [String: Any]) throws { exit(80) }
}
