import Foundation
import Security

struct TestFailure: Error {}
final class Provider: AuroraKeychainDefaultACLProvider {
    func prepare(accessibility: String) throws {}
    let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, .userPresence, nil)!
    var calls = 0
    func matches(_ candidate: CFTypeRef, accessibility: String, group: String) throws -> Bool {
        calls += 1
        return CFEqual(control, candidate) && accessibility == kSecAttrAccessibleWhenUnlocked as String && group == "fixture.group"
    }
}
final class API: AuroraKeychainAPI {
    let provider: Provider
    var reads = 0, writes = 0, wrongACL = false, unknown = false
    init(_ provider: Provider) { self.provider = provider }
    func copyMatching(_ q: [String: Any]) throws -> [[String: Any]] {
        let expected: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService,
            kSecAttrSynchronizable, kSecUseDataProtectionKeychain, kSecReturnAttributes, kSecMatchLimit]
            .map { $0 as String }.reduce(into: []) { $0.insert($1) }
        guard Set(q.keys) == expected, q[kSecClass as String] as? String == kSecClassGenericPassword as String,
              q[kSecAttrService as String] as? String == AuroraKeychainMigration.service,
              q[kSecAttrSynchronizable as String] as? Bool == false,
              q[kSecUseDataProtectionKeychain as String] as? Bool == true,
              q[kSecReturnAttributes as String] as? Bool == true,
              q[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String,
              let key = q[kSecAttrAccount as String] as? String, AuroraKeychainMigration.keys.contains(key) else { throw TestFailure() }
        reads += 1
        var row: [String: Any] = [kSecAttrAccount as String: key, kSecAttrService as String: AuroraKeychainMigration.service,
            kSecAttrSynchronizable as String: false, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrAccessGroup as String: "fixture.group", kSecAttrAccessControl as String: provider.control]
        if wrongACL { row[kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, .devicePasscode, nil)! }
        if unknown { row["unknown-field"] = "SECRET_MUST_NOT_PRINT" }
        return [row]
    }
    func update(_ query: [String: Any], attributes: [String: Any]) throws { writes += 1; throw TestFailure() }
}

private let entryProvider = Provider()
final class AuroraSystemKeychainAPI: AuroraKeychainAPI {
    private let api = API(entryProvider)
    func copyMatching(_ q: [String: Any]) throws -> [[String: Any]] {
        if ProcessInfo.processInfo.environment["AURORA_KEYCHAIN_ENTRY_FIXTURE"] == "no-query" { exit(78) }
        return try api.copyMatching(q)
    }
    func update(_ q: [String: Any], attributes: [String: Any]) throws { exit(79) }
}
enum AuroraSystemDefaultACLFactory {
    static func provider() throws -> AuroraKeychainDefaultACLProvider { exit(81) }
    static func qualify() throws -> AuroraKeychainDefaultACLProvider {
        let mode = ProcessInfo.processInfo.environment["AURORA_KEYCHAIN_ENTRY_FIXTURE"]
        if mode == "no-query" { exit(80) }
        if mode == "cleanup" { throw AuroraKeychainMigrationError.defaultACLCleanup }
        return entryProvider
    }
}
