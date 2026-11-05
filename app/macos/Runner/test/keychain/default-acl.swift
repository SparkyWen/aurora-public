import Foundation
import Security

struct QualificationTestFailure: Error {}
func require(_ value: @autoclosure () throws -> Bool) throws { if try !value() { throw QualificationTestFailure() } }
private let old = kSecAttrAccessibleWhenUnlocked as String
private let target = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
private let namespace = "12345678-1234-1234-1234-123456789abc"
private let service = "aurora.keychain-default-acl." + namespace
private let accounts = ["legacy", "background"]
private let attr = kSecAttrAccessible as String
private let acl = kSecAttrAccessControl as String
private let group = kSecAttrAccessGroup as String
private let account = kSecAttrAccount as String

final class Journal: AuroraKeychainNamespaceJournal {
    var created = false, complete = false, failCreate = false, failComplete = false
    var expectedAccounts = accounts
    func create(namespace value: String, service actualService: String, accounts actualAccounts: [String]) throws {
        try require(value == namespace && actualService == service && actualAccounts == expectedAccounts && !created)
        if failCreate { throw QualificationTestFailure() }
        created = true
    }
    func completed() throws {
        try require(created && !complete)
        if failComplete { throw QualificationTestFailure() }
        complete = true
    }
}

final class QualificationAPI: AuroraKeychainDefaultACLAPI {
    let journal: Journal
    let mode: String
    var rows = [String: [String: Any]]()
    var adds = 0, updates = 0, deletes = 0, reads = 0
    // The adapter boundary represents OS-created objects. UserPresence here
    // deliberately differs from the public flags=[] baseline; it is not a
    // claim that a real default keychain item carries this constraint.
    let controls = [old: SecAccessControlCreateWithFlags(nil, old as CFString, .userPresence, nil)!,
                   target: SecAccessControlCreateWithFlags(nil, target as CFString, .userPresence, nil)!]
    init(_ journal: Journal, _ mode: String = "okay") { self.journal = journal; self.mode = mode }
    private func checkQuery(_ query: [String: Any], read: Bool) throws -> String {
        var fields: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService,
            kSecAttrSynchronizable, kSecUseDataProtectionKeychain].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        if read { fields.formUnion([kSecReturnAttributes as String, kSecMatchLimit as String]) }
        if query[group] != nil { fields.formUnion([group, attr]) }
        try require(Set(query.keys) == fields)
        try require(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        try require(query[kSecAttrService as String] as? String == service)
        try require(query[kSecAttrSynchronizable as String] as? Bool == false)
        try require(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        if read {
            try require(query[kSecReturnAttributes as String] as? Bool == true)
            try require(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        }
        guard let key = query[account] as? String, accounts.contains(key) else { throw QualificationTestFailure() }
        return key
    }
    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]] {
        let key = try checkQuery(query, read: true); reads += 1
        if mode == "collision" && adds == 0 { return [[account: key]] }
        if mode == "unbound" && key == "background" && rows[key] != nil { return [[account: "wrong"]] }
        if mode == "duplicate" && rows[key] != nil { return [rows[key]!, rows[key]!] }
        return rows[key].map { [$0] } ?? []
    }
    func add(_ attributes: [String: Any]) throws {
        try require(journal.created && !journal.complete)
        let fields: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService,
            kSecAttrSynchronizable, kSecUseDataProtectionKeychain, kSecAttrAccessible, kSecValueData]
            .map { $0 as String }.reduce(into: []) { $0.insert($1) }
        try require(Set(attributes.keys) == fields)
        try require(attributes[kSecValueData as String] as? Data == Data("aurora-public-default-acl-v1".utf8))
        var base = attributes; base.removeValue(forKey: attr); base.removeValue(forKey: kSecValueData as String)
        let key = try checkQuery(base, read: false)
        try require(rows[key] == nil && attributes[attr] as? String == (key == "legacy" ? old : target))
        adds += 1
        if mode == "legacy-unavailable" && key == "legacy" { throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) }
        if mode == "second-add" && adds == 2 { throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) }
        var row = attributes; row.removeValue(forKey: kSecValueData as String)
        row.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        row[group] = "fixture.group"; row[acl] = controls[attributes[attr] as! String]
        for name in ["musr", "sha1", "tomb"] { row[name] = Data([1, 2, 3]) }
        if mode == "group-different" && key == "background" { row[group] = "another.group" }
        if mode == "unknown" { row[kSecAttrGeneric as String] = Data([0]) }
        rows[key] = row
    }
    func update(_ query: [String: Any], attributes: [String: Any]) throws {
        let key = try checkQuery(query, read: false)
        try require(key == "legacy" && query[group] as? String == "fixture.group")
        try require(Set(attributes.keys) == [attr] && rows[key]?[attr] as? String == query[attr] as? String)
        updates += 1
        if mode == "update-fails" || (mode == "rollback-fails" && updates == 2) { throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) }
        if mode != "update-noop" {
            rows[key]?[attr] = attributes[attr]
            rows[key]?[acl] = controls[attributes[attr] as! String]
        }
        if mode == "unexpected-acl" { rows[key]?[acl] = SecAccessControlCreateWithFlags(nil, target as CFString, [], nil)! }
        if mode == "identity-swap" { rows[key]?[account] = "wrong" }
    }
    func remove(_ query: [String: Any]) throws {
        let key = try checkQuery(query, read: false)
        try require(query[group] as? String == rows[key]?[group] as? String)
        try require(query[attr] as? String == rows[key]?[attr] as? String)
        try require(journal.created && !journal.complete)
        deletes += 1
        if mode == "delete-fails" { throw AuroraKeychainMigrationError.security(errSecInteractionNotAllowed) }
        if mode != "delete-noop" { rows.removeValue(forKey: key) }
    }
}

@main struct Tests {
    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "journal-lock-probe" {
            do {
                let next = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                try AuroraKeychainFileNamespaceJournal(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                    .create(namespace: next, service: "aurora.keychain-default-acl." + next, accounts: ["background"])
                exit(9)
            } catch { exit(0) }
        }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS default ACL \(name)") }
            catch { failed += 1; print("FAIL default ACL \(name)") }
        }
        test("two defaults exercise update and rollback then clean before returning RAM baselines") {
            let journal = Journal(); let api = QualificationAPI(journal)
            let provider = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace)
            try require(api.adds == 2 && api.updates == 2 && api.deletes == 2 && api.rows.isEmpty && journal.complete)
            for accessibility in [old, target] {
                try require(try provider.matches(api.controls[accessibility]!, accessibility: accessibility, group: "fixture.group"))
                try require(try !provider.matches(api.controls[accessibility]!, accessibility: accessibility, group: "other.group"))
                let different = SecAccessControlCreateWithFlags(nil, accessibility as CFString, [], nil)!
                try require(try !provider.matches(different, accessibility: accessibility, group: "fixture.group"))
            }
            let reads = api.reads
            _ = try provider.matches(api.controls[old]!, accessibility: old, group: "fixture.group")
            try require(api.reads == reads && api.adds == 2 && api.deletes == 2)
        }
        test("background seed never queries or creates legacy or updates a dummy") {
            let journal = Journal(); journal.expectedAccounts = ["background"]
            let api = QualificationAPI(journal, "legacy-unavailable")
            let provider = try AuroraKeychainDefaultACLQualification(api: api, journal: journal)
                .seed(namespace: namespace, accessibility: target)
            try require(api.adds == 1 && api.updates == 0 && api.deletes == 1 && api.rows.isEmpty && journal.complete)
            try require(try provider.matches(api.controls[target]!, accessibility: target, group: "fixture.group"))
        }
        test("lazy invocation only seeds requested background once even if legacy cannot be created") {
            var calls = [String]()
            let provider = AuroraKeychainLazyDefaultACLProvider { accessibility in
                calls.append(accessibility)
                let journal = Journal(); journal.expectedAccounts = ["background"]
                return try AuroraKeychainDefaultACLQualification(api: QualificationAPI(journal, "legacy-unavailable"), journal: journal)
                    .seed(namespace: namespace, accessibility: accessibility)
            }
            let control = SecAccessControlCreateWithFlags(nil, target as CFString, .userPresence, nil)!
            try provider.prepare(accessibility: target)
            for _ in 0..<7 { try require(try provider.matches(control, accessibility: target, group: "fixture.group")) }
            try require(calls == [target])
        }
        for mode in ["second-add", "update-fails", "rollback-fails", "update-noop"] {
            test("\(mode) refuses but cleans exact created items") {
                let journal = Journal(); let api = QualificationAPI(journal, mode)
                var refused = false
                do { _ = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace) }
                catch { refused = true }
                try require(refused && api.rows.isEmpty && journal.complete && api.deletes > 0)
            }
        }
        for mode in ["unbound", "duplicate", "unknown", "unexpected-acl", "identity-swap", "delete-fails", "delete-noop"] {
            test("\(mode) cannot falsely confirm cleanup or publish baseline") {
                let journal = Journal(); let api = QualificationAPI(journal, mode)
                var refused = false
                do { _ = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace) }
                catch { refused = true }
                try require(refused && !api.rows.isEmpty && !journal.complete)
            }
        }
        test("collision has no Add or Delete") {
            let journal = Journal(); let api = QualificationAPI(journal, "collision")
            do { _ = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace) }
            catch { try require(api.adds == 0 && api.updates == 0 && api.deletes == 0); return }
            throw QualificationTestFailure()
        }
        test("group mismatch refuses before dummy updates") {
            let journal = Journal(); let api = QualificationAPI(journal, "group-different")
            do { _ = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace) }
            catch { try require(api.updates == 0); return }
            throw QualificationTestFailure()
        }
        test("journal durability failure prevents all Security operations") {
            let journal = Journal(); journal.failCreate = true; let api = QualificationAPI(journal)
            do { _ = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace) }
            catch { try require(api.reads == 0 && api.adds == 0 && api.updates == 0 && api.deletes == 0); return }
            throw QualificationTestFailure()
        }
        test("journal completion failure does not return a baseline") {
            let journal = Journal(); journal.failComplete = true; let api = QualificationAPI(journal)
            do { _ = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace) }
            catch { try require(api.rows.isEmpty && api.deletes == 2 && !journal.complete); return }
            throw QualificationTestFailure()
        }
        test("noncanonical namespace rejected before journal and Security") {
            let journal = Journal(); let api = QualificationAPI(journal)
            do { _ = try AuroraKeychainDefaultACLQualification(api: api, journal: journal).run(namespace: namespace + "\n") }
            catch { try require(!journal.created && api.reads == 0); return }
            throw QualificationTestFailure()
        }
        test("real journal is private, durable, no-overwrite and removed only on completion") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("journal")
            let store = AuroraKeychainFileNamespaceJournal(directory: directory)
            try store.create(namespace: namespace, service: service, accounts: accounts)
            let file = directory.appendingPathComponent(namespace + ".json")
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            try require(metadata["namespace"] as? String == namespace && metadata["service"] as? String == service)
            try require(metadata["accounts"] as? [String] == accounts && metadata.count == 4)
            for (url, mode) in [(directory, 0o700), (file, 0o600)] {
                try require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == mode)
            }
            let another = AuroraKeychainFileNamespaceJournal(directory: directory)
            var refused = false
            do { try another.create(namespace: namespace, service: service, accounts: accounts) } catch { refused = true }
            try require(refused && FileManager.default.fileExists(atPath: file.path))
            try store.completed(); try require(!FileManager.default.fileExists(atPath: file.path))
        }
        test("journal rejects symlink directory without changing target") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let link = parent.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
            let store = AuroraKeychainFileNamespaceJournal(directory: link)
            do { try store.create(namespace: namespace, service: service, accounts: accounts) }
            catch { try require(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["link"]); return }
            throw QualificationTestFailure()
        }
        test("journal completion cannot delete a replaced namespace record") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("journal")
            let store = AuroraKeychainFileNamespaceJournal(directory: directory)
            try store.create(namespace: namespace, service: service, accounts: accounts)
            let file = directory.appendingPathComponent(namespace + ".json")
            try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("preserved.json"))
            try Data("replacement".utf8).write(to: file)
            do { try store.completed() }
            catch { try require(try Data(contentsOf: file) == Data("replacement".utf8)); return }
            throw QualificationTestFailure()
        }
        test("journal directory special permission bits are rejected") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o2700], ofItemAtPath: directory.path)
            let store = AuroraKeychainFileNamespaceJournal(directory: directory)
            do { try store.create(namespace: namespace, service: service, accounts: accounts) }
            catch { try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty); return }
            throw QualificationTestFailure()
        }
        test("journal record special permission bits are rejected before deletion") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("journal")
            let store = AuroraKeychainFileNamespaceJournal(directory: directory)
            try store.create(namespace: namespace, service: service, accounts: accounts)
            let file = directory.appendingPathComponent(namespace + ".json")
            try FileManager.default.setAttributes([.posixPermissions: 0o4600], ofItemAtPath: file.path)
            do { try store.completed() }
            catch { try require(FileManager.default.fileExists(atPath: file.path)); return }
            throw QualificationTestFailure()
        }
        test("real journal permits only the requested single background fixture account") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let store = AuroraKeychainFileNamespaceJournal(directory: parent.appendingPathComponent("journal"))
            try store.create(namespace: namespace, service: service, accounts: ["background"])
            try store.completed()
        }
        test("a previous incomplete namespace blocks future new dummy attempts without deleting evidence") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("journal")
            do {
                let oldStore = AuroraKeychainFileNamespaceJournal(directory: directory)
                try oldStore.create(namespace: namespace, service: service, accounts: accounts)
            }
            let oldFile = directory.appendingPathComponent(namespace + ".json")
            let evidence = try Data(contentsOf: oldFile)
            let next = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            let store = AuroraKeychainFileNamespaceJournal(directory: directory)
            do { try store.create(namespace: next, service: "aurora.keychain-default-acl." + next, accounts: ["background"]) }
            catch {
                try require(try Data(contentsOf: oldFile) == evidence)
                try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(next + ".json").path))
                return
            }
            throw QualificationTestFailure()
        }
        test("owner lock excludes another process even when no namespace filename remains visible") {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("journal")
            let store = AuroraKeychainFileNamespaceJournal(directory: directory)
            try store.create(namespace: namespace, service: service, accounts: accounts)
            try FileManager.default.moveItem(at: directory.appendingPathComponent(namespace + ".json"),
                                             to: parent.appendingPathComponent("retained.json"))
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["journal-lock-probe", directory.path]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
            let deadline = Date().addingTimeInterval(3)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { child.terminate(); throw QualificationTestFailure() }
            try require(child.terminationStatus == 0)
            withExtendedLifetime(store) {}
        }
        print("Default ACL: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
