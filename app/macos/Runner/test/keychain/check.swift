import Foundation
import Security

struct CheckFailure: Error {}
final class ReadOnlyAPI: AuroraKeychainAPI {
    let keys = ["aurora_contract_json", "aurora_delivery_url", "aurora_mode",
                "aurora_path_preference", "aurora_egress_lease_json",
                "aurora_route_family", "aurora_egress_interface"]
    var rows = [String: [[String: Any]]]()
    var queries = [String]()
    var updates = 0
    var error: Error?
    init() {
        for key in keys {
            rows[key] = [[kSecAttrAccount as String: key,
                kSecAttrService as String: "flutter_secure_storage_service",
                kSecAttrAccessGroup as String: "fixture.group",
                kSecAttrSynchronizable as String: false,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]]
        }
    }
    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]] {
        let expected: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService,
            kSecAttrSynchronizable, kSecUseDataProtectionKeychain,
            kSecReturnAttributes, kSecMatchLimit].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        guard Set(query.keys) == expected,
              query[kSecClass as String] as? String == kSecClassGenericPassword as String,
              query[kSecAttrService as String] as? String == "flutter_secure_storage_service",
              query[kSecAttrSynchronizable as String] as? Bool == false,
              query[kSecUseDataProtectionKeychain as String] as? Bool == true,
              query[kSecReturnAttributes as String] as? Bool == true,
              query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String,
              let key = query[kSecAttrAccount as String] as? String, keys.contains(key) else {
            throw CheckFailure()
        }
        queries.append(key)
        if let error { throw error }
        return rows[key] ?? []
    }
    func update(_ query: [String: Any], attributes: [String: Any]) throws {
        updates += 1
        throw CheckFailure()
    }
}

@main struct Tests {
    static func main() {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Bool) {
            do {
                guard try body() else { throw CheckFailure() }
                passed += 1; print("PASS check \(name)")
            } catch { failed += 1; print("FAIL check \(name)") }
        }
        let valid = ["/fixture/aurora", "--check-keychain-accessibility"]
        test("mixed seven items return aggregate counts without value queries or writes") {
            let api = ReadOnlyAPI()
            api.rows[api.keys[0]]![0][kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            api.rows[api.keys[1]] = []
            let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
            return result.exitCode == 0 &&
                result.message == "KEYCHAIN_ACCESSIBILITY_COMPATIBLE legacy=5 background=1 absent=1\n" &&
                api.queries == api.keys && api.updates == 0
        }
        test("observed metadata shape permits the unchanged default access-control check") {
            let api = ReadOnlyAPI()
            for key in api.keys {
                for name in ["musr", "sha1", "tomb"] { api.rows[key]![0][name] = Data("SENSITIVE_METADATA_NOT_TO_READ".utf8) }
                api.rows[key]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, [], nil)!
            }
            let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
            return result.exitCode == 0 && result.message == "KEYCHAIN_ACCESSIBILITY_COMPATIBLE legacy=7 background=0 absent=0\n" &&
                api.queries == api.keys && api.updates == 0
        }
        for field in [kSecValueData as String, kSecValueRef as String, kSecValuePersistentRef as String, kSecAttrTokenID as String] {
            test("known system metadata does not admit value, reference or token fields: \(field)") {
                let api = ReadOnlyAPI()
                for name in ["musr", "sha1", "tomb", field] { api.rows[api.keys[6]]![0][name] = "PRIVATE_VALUE" }
                let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
                return result.exitCode == 3 && !result.message.contains("PRIVATE_VALUE") && api.updates == 0
            }
        }
        test("known system metadata cannot bypass access-control constraints") {
            let api = ReadOnlyAPI()
            for name in ["musr", "sha1", "tomb"] { api.rows[api.keys[6]]![0][name] = true }
            api.rows[api.keys[6]]![0][kSecAttrAccessControl as String] =
                SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, .userPresence, nil)!
            let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
            return result.exitCode == 3 && result.message == "KEYCHAIN_ACCESSIBILITY_REFUSED reason=qualification-required\n" && api.updates == 0
        }
        test("all absent remains an explicit seven-item snapshot, not a value-read proof") {
            let api = ReadOnlyAPI(); api.rows = [:]
            let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
            return result.exitCode == 0 &&
                result.message == "KEYCHAIN_ACCESSIBILITY_COMPATIBLE legacy=0 background=0 absent=7\n" &&
                api.queries == api.keys && api.updates == 0
        }
        test("default public access-control equality uses the migration policy") {
            let api = ReadOnlyAPI()
            api.rows[api.keys[0]]![0][kSecAttrAccessControl as String] =
                SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, [], nil)!
            let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
            return result.exitCode == 0 && api.queries == api.keys && api.updates == 0
        }
        for (scenario, expectedReason) in [("unknown", "unknown-attributes schema=unrecognized-present"), ("user-presence", "qualification-required"),
            ("duplicate", "multiple-matches"), ("identity", "identity"), ("group", "group"),
            ("class", "identity"), ("synchronizable", "identity"), ("unsupported-accessibility", "accessibility")] {
            test("\(scenario) refuses without partial counts or mutation") {
                let api = ReadOnlyAPI(); let last = api.keys[6]
                switch scenario {
                case "unknown": api.rows[last]![0]["unknown-security-attribute"] = true
                case "user-presence": api.rows[last]![0][kSecAttrAccessControl as String] =
                    SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, .userPresence, nil)!
                case "duplicate": api.rows[last]!.append(api.rows[last]![0])
                case "identity": api.rows[last]![0][kSecAttrService as String] = "private.sentinel.service"
                case "group": api.rows[last]![0].removeValue(forKey: kSecAttrAccessGroup as String)
                case "class": api.rows[last]![0][kSecClass as String] = kSecClassInternetPassword
                case "synchronizable": api.rows[last]![0][kSecAttrSynchronizable as String] = true
                default: api.rows[last]![0][kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                }
                let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
                return result.exitCode == 3 && result.message == "KEYCHAIN_ACCESSIBILITY_REFUSED reason=\(expectedReason)\n" &&
                    api.queries == api.keys && api.updates == 0
            }
        }
        let metadata: [(CFString, String)] = [
            (kSecAttrGeneric, "generic"), (kSecAttrIsInvisible, "invisible"),
            (kSecAttrIsNegative, "negative"), (kSecAttrCreator, "creator"),
            (kSecAttrType, "type"), (kSecAttrTokenID, "token-id"),
            (kSecAttrAccess, "legacy-access"), (kSecAttrApplicationLabel, "application-label"),
            (kSecAttrApplicationTag, "application-tag"), (kSecAttrIsPermanent, "permanent")]
        for (attribute, category) in metadata {
            test("unknown public metadata \(category) only reports its fixed presence category") {
                let api = ReadOnlyAPI()
                api.rows[api.keys[0]]![0][attribute as String] = Data("PRIVATE_VALUE_SENTINEL".utf8)
                let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
                return result.exitCode == 3 && result.message ==
                    "KEYCHAIN_ACCESSIBILITY_REFUSED reason=unknown-attributes schema=\(category)\n" &&
                    api.queries.count == 1 && api.updates == 0
            }
        }
        test("mixed metadata is deterministic and never reveals raw unknown keys, values or their hashes") {
            let api = ReadOnlyAPI()
            for (attribute, _) in metadata {
                api.rows[api.keys[0]]![0][attribute as String] = "PRIVATE_VALUE_SENTINEL"
            }
            api.rows[api.keys[0]]![0]["PRIVATE_UNKNOWN_ACCOUNT_NAME"] = Data("PRIVATE_DATA".utf8)
            api.rows[api.keys[0]]![0]["PRIVATE_SECOND_UNKNOWN_NAME"] = "PRIVATE_DATA"
            let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
            return result.exitCode == 3 && result.message ==
                "KEYCHAIN_ACCESSIBILITY_REFUSED reason=unknown-attributes schema=application-label,application-tag,creator,generic,invisible,legacy-access,negative,permanent,token-id,type,unrecognized-present\n" &&
                api.queries.count == 1 && api.updates == 0
        }
        for status: OSStatus in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement] {
            test("security status \(status) is classified without original error text") {
                let api = ReadOnlyAPI(); api.error = AuroraKeychainMigrationError.security(status)
                let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
                return result.exitCode == (status == errSecInteractionNotAllowed ? 2 : 3) &&
                    result.message == (status == errSecInteractionNotAllowed
                        ? "KEYCHAIN_ACCESSIBILITY_LOCKED\n" : "KEYCHAIN_ACCESSIBILITY_REFUSED reason=security status=\(status)\n") &&
                    api.queries.count == 1 && api.updates == 0
            }
        }
        test("unknown error is refused without original text") {
            let api = ReadOnlyAPI(); api.error = NSError(domain: "private-sentinel-path-or-account", code: 91)
            let result = AuroraKeychainReadOnlyCheck(api: api).run(valid)
            return result.exitCode == 3 && result.message == "KEYCHAIN_ACCESSIBILITY_REFUSED reason=unexpected\n" && api.updates == 0
        }
        for args in [[], ["--check-keychain-accessibility=extra"],
                     ["--check-keychain-accessibility", "--start-vpn"],
                     ["--check-keychain-accessibility", "--check-keychain-accessibility"],
                     ["--rollback-keychain-accessibility", "--check-keychain-accessibility"]] {
            test("invalid arguments are rejected before any Security call: \(args.count) arguments") {
                let api = ReadOnlyAPI()
                let result = AuroraKeychainReadOnlyCheck(api: api).run(["/fixture/aurora"] + args)
                return result.exitCode == 3 && result.message == "KEYCHAIN_ACCESSIBILITY_REFUSED reason=arguments\n" &&
                    api.queries.isEmpty && api.updates == 0
            }
        }
        print("Read-only keychain check: \(passed) passed, \(failed) failed (API double; no real Keychain access)")
        exit(failed == 0 ? 0 : 1)
    }
}
