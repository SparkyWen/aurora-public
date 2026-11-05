import Foundation
import Security

struct Failed: Error {}
var passed = 0
var failed = 0
func check(_ value: @autoclosure () -> Bool) throws { if !value() { throw Failed() } }
func refuses(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failed()
}
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { failed += 1; print("FAIL \(name): \(type(of: error))") }
}
let old = kSecAttrAccessibleWhenUnlocked as String
let target = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
let account = kSecAttrAccount as String
let accessible = kSecAttrAccessible as String
let group = kSecAttrAccessGroup as String
let keys = ["aurora_contract_json", "aurora_delivery_url", "aurora_mode", "aurora_path_preference",
            "aurora_egress_lease_json", "aurora_route_family", "aurora_egress_interface"]
func item(_ key: String, _ access: String = old) -> [String: Any] {
    [account: key, kSecAttrService as String: "flutter_secure_storage_service",
     accessible: access, group: "fixture.group", kSecAttrSynchronizable as String: false]
}
final class Receipt: AuroraKeychainReceiptStore {
    var saved: AuroraKeychainReceipt?
    var denied = false
    var locked = false
    var writes = 0
    func lock() throws { try check(!locked); locked = true }
    func unlock() { locked = false }
    func load() throws -> AuroraKeychainReceipt? { try check(locked); return saved }
    func create(_ receipt: AuroraKeychainReceipt) throws {
        try check(locked)
        if denied { throw AuroraKeychainMigrationError.receipt }
        try check(saved == nil); saved = receipt; writes += 1
    }
}
final class API: AuroraKeychainAPI {
    var rows = Dictionary(uniqueKeysWithValues: keys.map { ($0, [item($0)]) })
    var queries = [[String: Any]]()
    var updates = 0
    var failAt: Int?
    var readError: OSStatus?
    var corruptUpdate = false
    var systemACL = false
    let receipt: Receipt
    init(_ receipt: Receipt) { self.receipt = receipt }
    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]] {
        try check(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        try check(query[kSecAttrService as String] as? String == "flutter_secure_storage_service")
        try check(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        try check(query[kSecAttrSynchronizable as String] as? Bool == false)
        try check(query[kSecReturnAttributes as String] as? Bool == true)
        try check(query[kSecReturnData as String] == nil && query[kSecValueData as String] == nil)
        try check(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        guard let key = query[account] as? String, keys.contains(key) else { throw Failed() }
        queries.append(query)
        if let status = readError { throw AuroraKeychainMigrationError.security(status) }
        return rows[key] ?? []
    }
    func update(_ query: [String: Any], attributes: [String: Any]) throws {
        try check(receipt.saved != nil && receipt.locked)
        try check(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        try check(query[kSecAttrService as String] as? String == "flutter_secure_storage_service")
        try check(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        try check(query[kSecAttrSynchronizable as String] as? Bool == false)
        try check(query[group] as? String == "fixture.group")
        try check(attributes.count == 1 && attributes[accessible] != nil)
        let expected: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService, kSecAttrSynchronizable,
            kSecUseDataProtectionKeychain, kSecAttrAccessGroup, kSecAttrAccessible]
            .map { $0 as String }.reduce(into: []) { $0.insert($1) }
        try check(Set(query.keys) == expected)
        guard let key = query[account] as? String, var row = rows[key]?.first else { throw Failed() }
        try check(row[accessible] as? String == query[accessible] as? String)
        updates += 1
        if failAt == updates { throw AuroraKeychainMigrationError.security(-25308) }
        if !corruptUpdate {
            row[accessible] = attributes[accessible]
            if row[kSecAttrAccessControl as String] != nil {
                row[kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, attributes[accessible] as! CFString, systemACL ? .userPresence : [], nil)!
            }
            rows[key] = [row]
        }
    }
}
func fixture() -> (AuroraKeychainMigration, API, Receipt) {
    let r = Receipt(); let a = API(r)
    return (AuroraKeychainMigration(api: a, receipts: r, defaults: { NoDefaultACLs() }), a, r)
}

struct NoDefaultACLs: AuroraKeychainDefaultACLProvider {
    func prepare(accessibility: String) throws {}
    func matches(_ control: CFTypeRef, accessibility: String, group: String) throws -> Bool { false }
}
struct SystemFixtureACLs: AuroraKeychainDefaultACLProvider {
    func prepare(accessibility: String) throws {}
    func matches(_ control: CFTypeRef, accessibility: String, group: String) throws -> Bool {
        guard group == "fixture.group", [old, target].contains(accessibility) else { return false }
        return CFEqual(control, SecAccessControlCreateWithFlags(nil, accessibility as CFString, .userPresence, nil)!)
    }
}

test("one RAM system baseline per locked prepare or rollback, never per item or across calls") {
    let r = Receipt(); let a = API(r); a.systemACL = true
    for key in keys { a.rows[key]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, old as CFString, .userPresence, nil)! }
    var calls = 0
    let m = AuroraKeychainMigration(api: a, receipts: r, defaults: {
        try check(r.locked); calls += 1; return SystemFixtureACLs()
    })
    try m.prepare(); try check(calls == 1 && a.updates == 7 && r.writes == 1)
    try m.prepare(); try check(calls == 2 && a.updates == 7 && r.writes == 1)
    try m.rollback(); try check(calls == 3 && a.updates == 14 && !r.locked)
    try check(a.rows.values.allSatisfy { $0.first?[accessible] as? String == old })
}
test("baseline cleanup failure blocks production reads, receipt creation and updates") {
    let r = Receipt(); let a = API(r); var calls = 0
    let m = AuroraKeychainMigration(api: a, receipts: r, defaults: {
        calls += 1; try check(r.locked); throw AuroraKeychainMigrationError.defaultACLCleanup
    })
    try refuses { try m.prepare() }
    try check(calls == 1 && a.queries.isEmpty && a.updates == 0 && r.writes == 0 && r.saved == nil && !r.locked)
}
test("a non-default production ACL is still refused before receipt or any production write") {
    let r = Receipt(); let a = API(r); var calls = 0
    for key in keys { a.rows[key]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, old as CFString, .userPresence, nil)! }
    a.rows[keys.last!]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, old as CFString, .devicePasscode, nil)!
    let m = AuroraKeychainMigration(api: a, receipts: r, defaults: { calls += 1; return SystemFixtureACLs() })
    try refuses { try m.prepare() }
    try check(calls == 1 && a.queries.count == 7 && a.updates == 0 && r.saved == nil)
}
test("rollback baseline failure leaves migrated items and durable original receipt unchanged") {
    let r = Receipt(); let a = API(r); var calls = 0
    let m = AuroraKeychainMigration(api: a, receipts: r, defaults: {
        calls += 1
        if calls == 2 { throw AuroraKeychainMigrationError.defaultACLCleanup }
        return NoDefaultACLs()
    })
    try m.prepare(); let receipt = r.saved; a.queries = []
    try refuses { try m.rollback() }
    try check(calls == 2 && a.queries.isEmpty && a.updates == 7 && r.saved == receipt && !r.locked)
}
test("missing rollback receipt refuses before creating any dummy baseline") {
    let r = Receipt(); let a = API(r); var calls = 0
    let m = AuroraKeychainMigration(api: a, receipts: r, defaults: { calls += 1; return NoDefaultACLs() })
    try refuses { try m.rollback() }
    try check(calls == 0 && a.queries.isEmpty && a.updates == 0)
}
test("fully background items prepare and no-op rollback without any unavailable legacy seed") {
    let r = Receipt(); let a = API(r); var seeded = [String]()
    for key in keys {
        a.rows[key]![0][accessible] = target
        a.rows[key]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, target as CFString, .userPresence, nil)!
    }
    let m = AuroraKeychainMigration(api: a, receipts: r, defaults: {
        AuroraKeychainLazyDefaultACLProvider { accessibility in
            seeded.append(accessibility)
            if accessibility == old { throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) }
            return SystemFixtureACLs()
        }
    })
    try m.prepare(); try m.rollback()
    try check(seeded == [target, target] && a.updates == 0 && r.writes == 1 && !r.locked)
}
test("target baseline must finish cleanup before receipt creation or any legacy production update") {
    let r = Receipt(); let a = API(r); var seeded = [String]()
    let m = AuroraKeychainMigration(api: a, receipts: r, defaults: {
        AuroraKeychainLazyDefaultACLProvider { accessibility in
            seeded.append(accessibility); throw AuroraKeychainMigrationError.defaultACLCleanup
        }
    })
    try refuses { try m.prepare() }
    try check(seeded == [target] && a.queries.count == 7 && a.updates == 0 && r.saved == nil && !r.locked)
}
test("rollback preflights necessary legacy baseline before changing any background production item") {
    let r = Receipt(); let a = API(r)
    let first = AuroraKeychainMigration(api: a, receipts: r, defaults: { NoDefaultACLs() })
    try first.prepare(); var seeded = [String](); a.queries = []
    let rollback = AuroraKeychainMigration(api: a, receipts: r, defaults: {
        AuroraKeychainLazyDefaultACLProvider { accessibility in
            seeded.append(accessibility)
            if accessibility == old { throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) }
            return NoDefaultACLs()
        }
    })
    try refuses { try rollback.rollback() }
    try check(seeded == [old] && a.queries.count == 7 && a.updates == 7 && !r.locked)
    try check(a.rows.values.allSatisfy { $0.first?[accessible] as? String == target })
}

test("legacy attributes migrate in place only after durable receipt; repeat is idempotent") {
    let (m, a, r) = fixture(); try m.prepare()
    try check(a.updates == 7 && r.writes == 1)
    try check(a.rows.values.allSatisfy { $0.first?[accessible] as? String == target })
    try check(r.saved?.items.allSatisfy { $0.previousAccessibility == old } == true)
    try check(a.queries.allSatisfy { $0[accessible] == nil })
    try m.prepare(); try check(a.updates == 7 && r.writes == 1 && !r.locked)
}
test("observed system metadata survives in-place migration and rollback without entering writes or receipt") {
    let (m, a, r) = fixture()
    let metadata = ["musr": Data([1, 2]), "sha1": Data([3, 4]), "tomb": Data([5, 6])]
    for key in keys {
        for (name, value) in metadata { a.rows[key]![0][name] = value }
        a.rows[key]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, old as CFString, [], nil)!
    }
    try m.prepare(); try m.prepare(); try check(a.updates == 7 && r.writes == 1)
    try m.rollback(); try check(a.updates == 14 && r.writes == 1)
    for key in keys {
        try check(a.rows[key]![0][accessible] as? String == old)
        for (name, value) in metadata { try check(a.rows[key]![0][name] as? Data == value) }
    }
    let receiptJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.saved!)) as! [String: Any]
    try check((receiptJSON["items"] as! [[String: Any]]).allSatisfy {
        Set($0.keys) == ["key", "previousAccessibility", "accessGroup"]
    })
    let expected: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService, kSecAttrSynchronizable,
        kSecUseDataProtectionKeychain, kSecReturnAttributes, kSecMatchLimit].map { $0 as String }.reduce(into: []) { $0.insert($1) }
    try check(a.queries.allSatisfy { Set($0.keys) == expected })
}
test("receipt persistence failure prevents every mutation") {
    let (m, a, r) = fixture(); r.denied = true
    try refuses { try m.prepare() }; try check(a.updates == 0 && !r.locked)
}
test("inaccessible keychain is an error, never missing items or migration success") {
    let (m, a, r) = fixture(); a.readError = -25308
    try refuses { try m.prepare() }; try check(a.updates == 0 && r.saved == nil)
}
test("ambiguous access groups fail before receipt or mutation") {
    let (m, a, r) = fixture(); a.rows[keys[6]] = [item(keys[6]), item(keys[6])]
    try refuses { try m.prepare() }; try check(a.updates == 0 && r.saved == nil)
}
test("unknown accessibility or access control fails before any mutation") {
    for field in [accessible, kSecAttrAccessControl as String, "unknown-security-attribute"] {
        let (m, a, r) = fixture(); a.rows[keys[6]]![0][field] = "unexpected"
        try refuses { try m.prepare() }; try check(a.updates == 0 && r.saved == nil)
    }
}
test("public default access-control equality is accepted; user-presence constraints are refused") {
    let (m, a, _) = fixture()
    a.rows[keys[0]]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, old as CFString, [], nil)!
    try m.prepare(); try check(a.updates == 7)
    let (guarded, protected, _) = fixture()
    protected.rows[keys[0]]![0][kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, old as CFString, .userPresence, nil)!
    try refuses { try guarded.prepare() }; try check(protected.updates == 0)
}
test("partial migration resumes against original receipt without erasing rollback metadata") {
    let (m, a, r) = fixture(); a.failAt = 3
    try refuses { try m.prepare() }; let receipt = r.saved
    try check(a.rows[keys[0]]![0][accessible] as? String == target)
    a.failAt = nil; try m.prepare()
    try check(r.saved == receipt && r.writes == 1 && a.updates == 8)
}
test("readback must confirm update; API success alone cannot release barrier") {
    let (m, a, _) = fixture(); a.corruptUpdate = true
    try refuses { try m.prepare() }; try check(a.updates == 1)
}
test("existing target and missing keys are safe; rollback preserves newly written values") {
    let (m, a, r) = fixture(); a.rows[keys[0]] = [item(keys[0], target)]; a.rows[keys[1]] = []
    try m.prepare(); try check(a.updates == 5)
    // A value created by the new application after migration must remain readable by old options.
    a.rows[keys[1]] = [item(keys[1], target)]
    try m.rollback()
    try check(a.rows[keys[0]]![0][accessible] as? String == target)
    try check(keys.dropFirst().allSatisfy { a.rows[$0]![0][accessible] as? String == old })
    let count = a.updates; try m.rollback(); try check(a.updates == count && r.writes == 1)
}
test("rollback without original receipt is refused") {
    let (m, a, _) = fixture(); try refuses { try m.rollback() }; try check(a.updates == 0)
}
test("receipt tampering or access group change is refused") {
    let (m, a, r) = fixture(); try m.prepare()
    a.rows[keys[0]]![0][group] = "other.group"
    let count = a.updates
    try refuses { try m.prepare() }; try refuses { try m.rollback() }; try check(a.updates == count)
    r.saved = AuroraKeychainReceipt(schema: 1, service: "other", items: r.saved!.items)
    try refuses { try m.prepare() }; try check(a.updates == count)
}
test("actual receipt file is private, immutable, and reloadable without secret fields") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = AuroraKeychainFileReceiptStore(directory: dir)
    let receipt = AuroraKeychainReceipt(schema: 1, service: "flutter_secure_storage_service",
        items: keys.map { .init(key: $0, previousAccessibility: old, accessGroup: "fixture.group") })
    try store.lock(); defer { store.unlock() }
    try store.create(receipt); let reloaded = try store.load(); try check(reloaded == receipt)
    let path = dir.appendingPathComponent("receipt.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let data = try Data(contentsOf: path)
    let doc = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    try check(Set(doc.keys) == ["schema", "service", "items"])
    try check((doc["items"] as! [[String: Any]]).allSatisfy {
        Set($0.keys) == ["key", "previousAccessibility", "accessGroup"]
    })
    try refuses { try store.create(receipt) }
    let another = AuroraKeychainFileReceiptStore(directory: dir)
    try refuses { try another.lock() }
}
test("receipt refuses symlink directory, unsafe permissions, and symlink file") {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    let link = base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
    let linked = AuroraKeychainFileReceiptStore(directory: link)
    try refuses { try linked.lock() }
    let store = AuroraKeychainFileReceiptStore(directory: base)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
    try refuses { try store.lock() }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    try store.lock(); defer { store.unlock() }
    try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("receipt.json"), withDestinationURL: link)
    try refuses { _ = try store.load() }
}
test("receipt refuses truncated metadata and non-private existing receipt") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = AuroraKeychainFileReceiptStore(directory: dir)
    try store.lock(); defer { store.unlock() }
    let path = dir.appendingPathComponent("receipt.json")
    try Data("{".utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    try refuses { _ = try store.load() }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    try refuses { _ = try store.load() }
}
print("Native keychain policy: \(passed) passed, \(failed) failed (Security API double; no real Keychain access)")
exit(failed == 0 ? 0 : 1)
