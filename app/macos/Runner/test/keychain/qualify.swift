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
@main struct Tests {
    static func main() {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () -> Bool) {
            if body() { passed += 1; print("PASS qualification \(name)") }
            else { failed += 1; print("FAIL qualification \(name)") }
        }
        let args = ["aurora", "--qualify-keychain-default-acl"]
        test("qualified OS baseline authorizes only a seven-item attribute snapshot") {
            let provider = Provider(); let api = API(provider); var called = 0
            let result = AuroraKeychainDefaultACLCheck(api: api, qualify: { called += 1; return provider }).run(args)
            return result.exitCode == 0 && result.message == "KEYCHAIN_DEFAULT_ACL_QUALIFIED legacy=7 background=0 absent=0 dummy-roundtrip=passed cleanup=confirmed\n" &&
                called == 1 && api.reads == 7 && api.writes == 0 && provider.calls == 7
        }
        for extra in [["--start-vpn"], [args[1]], ["--check-keychain-accessibility"]] {
            test("invalid args reject before journal, fixtures and production") {
                let provider = Provider(); let api = API(provider); var called = false
                let result = AuroraKeychainDefaultACLCheck(api: api, qualify: { called = true; return provider }).run(args + extra)
                return result.exitCode == 3 && result.message == "KEYCHAIN_DEFAULT_ACL_REFUSED reason=arguments\n" && !called && api.reads == 0
            }
        }
        test("cleanup failure blocks production reads and never outputs partial counts") {
            let provider = Provider(); let api = API(provider)
            let result = AuroraKeychainDefaultACLCheck(api: api, qualify: { throw AuroraKeychainMigrationError.defaultACLCleanup }).run(args)
            return result.exitCode == 3 && result.message == "KEYCHAIN_DEFAULT_ACL_REFUSED reason=fixture-cleanup\n" && api.reads == 0
        }
        test("locked dummy seed is failure with no production read") {
            let provider = Provider(); let api = API(provider)
            let result = AuroraKeychainDefaultACLCheck(api: api, qualify: { throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) }).run(args)
            return result.exitCode == 2 && result.message == "KEYCHAIN_DEFAULT_ACL_LOCKED\n" && api.reads == 0
        }
        test("qualified different access control remains refused") {
            let provider = Provider(); let api = API(provider); api.wrongACL = true
            let result = AuroraKeychainDefaultACLCheck(api: api, qualify: { provider }).run(args)
            return result.exitCode == 3 && result.message == "KEYCHAIN_DEFAULT_ACL_REFUSED reason=access-control\n" && api.writes == 0
        }
        test("unknown field remains refused without leaking key or value") {
            let provider = Provider(); let api = API(provider); api.unknown = true
            let result = AuroraKeychainDefaultACLCheck(api: api, qualify: { provider }).run(args)
            return result.exitCode == 3 && result.message == "KEYCHAIN_DEFAULT_ACL_REFUSED reason=unknown-attributes\n" && api.writes == 0
        }
        print("Qualification: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
