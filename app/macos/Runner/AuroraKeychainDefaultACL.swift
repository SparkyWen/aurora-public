import Foundation
import Security
import LocalAuthentication
import Darwin

protocol AuroraKeychainDefaultACLProvider {
    func prepare(accessibility: String) throws
    func matches(_ control: CFTypeRef, accessibility: String, group: String) throws -> Bool
}

final class AuroraKeychainLazyDefaultACLProvider: AuroraKeychainDefaultACLProvider {
    private let seed: (String) throws -> AuroraKeychainDefaultACLProvider
    private var cached = [String: AuroraKeychainDefaultACLProvider]()
    init(seed: @escaping (String) throws -> AuroraKeychainDefaultACLProvider) { self.seed = seed }
    func prepare(accessibility: String) throws {
        guard [kSecAttrAccessibleWhenUnlocked as String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String]
            .contains(accessibility) else { throw AuroraKeychainMigrationError.refused }
        if cached[accessibility] != nil { return }
        let value = try seed(accessibility)
        try value.prepare(accessibility: accessibility)
        cached[accessibility] = value
    }
    func matches(_ control: CFTypeRef, accessibility: String, group: String) throws -> Bool {
        try prepare(accessibility: accessibility)
        return try cached[accessibility]!.matches(control, accessibility: accessibility, group: group)
    }
}

protocol AuroraKeychainDefaultACLAPI: AuroraKeychainAPI {
    func add(_ attributes: [String: Any]) throws
    func remove(_ query: [String: Any]) throws
}

protocol AuroraKeychainNamespaceJournal {
    func create(namespace: String, service: String, accounts: [String]) throws
    func completed() throws
}

final class AuroraKeychainFileNamespaceJournal: AuroraKeychainNamespaceJournal {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private var directoryFD: Int32 = -1
    private var fileFD: Int32 = -1
    private var ownerFD: Int32 = -1
    private var fileName: String?
    deinit {
        releaseOwner()
        if fileFD >= 0 { close(fileFD) }
        if directoryFD >= 0 { close(directoryFD) }
    }
    private func releaseOwner() {
        if ownerFD >= 0 { flock(ownerFD, LOCK_UN); close(ownerFD); ownerFD = -1 }
    }
    private func admit() throws {
        ownerFD = openat(directoryFD, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try validate(ownerFD, directory: false)
        var held = stat(), named = stat()
        guard flock(ownerFD, LOCK_EX | LOCK_NB) == 0, fstat(ownerFD, &held) == 0,
              held.st_size == 0, fsync(ownerFD) == 0,
              fstatat(directoryFD, "owner.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw AuroraKeychainMigrationError.receipt }
        let duplicate = dup(directoryFD)
        guard duplicate >= 0 else { throw AuroraKeychainMigrationError.receipt }
        guard let listing = fdopendir(duplicate) else { close(duplicate); throw AuroraKeychainMigrationError.receipt }
        defer { closedir(listing) }
        // A completed invocation leaves only this persistent empty lock file.
        // Any other entry, including an interrupted namespace, requires explicit
        // recovery. Never read its contents, delete it, or start another seed.
        var entries = 0
        errno = 0
        while let entry = readdir(listing) {
            entries += 1
            guard entries <= 3 else { throw AuroraKeychainMigrationError.receipt }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name == "." || name == ".." || name == "owner.lock" else { throw AuroraKeychainMigrationError.receipt }
        }
        guard errno == 0 else { throw AuroraKeychainMigrationError.receipt }
    }
    private func validate(_ fd: Int32, directory: Bool) throws {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw AuroraKeychainMigrationError.receipt }
    }
    func create(namespace: String, service: String, accounts: [String]) throws {
        guard directoryFD == -1, let uuid = UUID(uuidString: namespace),
              uuid.uuidString.lowercased() == namespace,
              service == "aurora.keychain-default-acl." + namespace,
              [["legacy"], ["background"], ["legacy", "background"]].contains(accounts) else { throw AuroraKeychainMigrationError.receipt }
        let madeDirectory = mkdir(directory.path, 0o700) == 0
        if !madeDirectory && errno != EEXIST { throw AuroraKeychainMigrationError.receipt }
        directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try validate(directoryFD, directory: true)
        if madeDirectory {
            // Persist the new directory entry, not only the file inside it,
            // before SecItemAdd can leave a fixture requiring recovery.
            let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            defer { if parent >= 0 { close(parent) } }
            guard parent >= 0, fsync(parent) == 0 else { throw AuroraKeychainMigrationError.receipt }
        }
        try admit()
        let name = namespace + ".json"
        fileFD = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try validate(fileFD, directory: false)
        fileName = name
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "namespace": namespace,
            "service": service, "accounts": accounts], options: [.sortedKeys])
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { write(fileFD, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw AuroraKeychainMigrationError.receipt }
            offset += amount
        }
        guard fsync(fileFD) == 0, fsync(directoryFD) == 0 else { throw AuroraKeychainMigrationError.receipt }
    }
    func completed() throws {
        guard let fileName else { throw AuroraKeychainMigrationError.receipt }
        try validate(directoryFD, directory: true)
        try validate(fileFD, directory: false)
        var held = stat(), current = stat()
        guard fstat(fileFD, &held) == 0,
              fstatat(directoryFD, fileName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              unlinkat(directoryFD, fileName, 0) == 0, fsync(directoryFD) == 0 else {
            throw AuroraKeychainMigrationError.receipt
        }
        self.fileName = nil
        releaseOwner()
    }
}

struct AuroraKeychainDefaultACLQualification {
    let api: AuroraKeychainDefaultACLAPI
    let journal: AuroraKeychainNamespaceJournal
    private static let legacy = kSecAttrAccessibleWhenUnlocked as String
    private static let background = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private struct Binding {
        let accessibility: String
        let group: String
        let control: CFTypeRef
    }
    private struct Baselines: AuroraKeychainDefaultACLProvider {
        let values: [String: Binding]
        func prepare(accessibility: String) throws {
            guard values[accessibility] != nil else { throw AuroraKeychainMigrationError.refused }
        }
        func matches(_ control: CFTypeRef, accessibility: String, group: String) throws -> Bool {
            guard let value = values[accessibility], value.group == group,
                  CFGetTypeID(control) == SecAccessControlGetTypeID() else { return false }
            return CFEqual(control, value.control)
        }
    }

    private func query(_ key: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
         kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    private func read(_ key: String, service: String) throws -> [[String: Any]] {
        var q = query(key, service: service)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        return try api.copyMatching(q)
    }
    private func binding(_ key: String, service: String) throws -> Binding {
        let rows = try read(key, service: service)
        guard rows.count == 1 else { throw AuroraKeychainMigrationError.refused }
        let row = rows[0]
        let allowed: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService,
            kSecAttrAccessible, kSecAttrAccessGroup, kSecAttrSynchronizable,
            kSecAttrCreationDate, kSecAttrModificationDate, kSecAttrLabel,
            kSecAttrDescription, kSecAttrComment, kSecAttrAccessControl]
            .map { $0 as String }.reduce(into: ["musr", "sha1", "tomb"]) { $0.insert($1) }
        guard Set(row.keys).isSubset(of: allowed),
              row[kSecAttrAccount as String] as? String == key,
              row[kSecAttrService as String] as? String == service,
              row[kSecAttrSynchronizable as String] as? Bool == false,
              let group = row[kSecAttrAccessGroup as String] as? String, !group.isEmpty,
              let accessibility = row[kSecAttrAccessible as String] as? String,
              [Self.legacy, Self.background].contains(accessibility),
              let control = row[kSecAttrAccessControl as String],
              CFGetTypeID(control as CFTypeRef) == SecAccessControlGetTypeID() else {
            throw AuroraKeychainMigrationError.refused
        }
        if let klass = row[kSecClass as String], klass as? String != kSecClassGenericPassword as String {
            throw AuroraKeychainMigrationError.refused
        }
        return Binding(accessibility: accessibility, group: group, control: control as CFTypeRef)
    }
    private func exactQuery(_ key: String, service: String, binding: Binding) -> [String: Any] {
        var q = query(key, service: service)
        q[kSecAttrAccessGroup as String] = binding.group
        q[kSecAttrAccessible as String] = binding.accessibility
        return q
    }

    // Two public dummy items establish only OS-created default ACLs. Their
    // attributes exercise the same accessible-only update and rollback before
    // any baseline is released to a caller. No item value is ever requested.
    func seed(namespace: String, accessibility: String) throws -> AuroraKeychainDefaultACLProvider {
        guard [Self.legacy, Self.background].contains(accessibility) else { throw AuroraKeychainMigrationError.refused }
        return try run(namespace: namespace, accessibilities: [accessibility], exercise: false)
    }
    func run(namespace: String) throws -> AuroraKeychainDefaultACLProvider {
        try run(namespace: namespace, accessibilities: [Self.legacy, Self.background], exercise: true)
    }
    private func run(namespace: String, accessibilities: [String], exercise: Bool) throws -> AuroraKeychainDefaultACLProvider {
        guard let uuid = UUID(uuidString: namespace), uuid.uuidString.lowercased() == namespace else {
            throw AuroraKeychainMigrationError.refused
        }
        let service = "aurora.keychain-default-acl." + namespace
        let accounts = accessibilities.map { $0 == Self.legacy ? "legacy" : "background" }
        try journal.create(namespace: namespace, service: service, accounts: accounts)
        var created = Set<String>(), bound = [String: Binding](), values = [String: Binding]()
        var operationError: Error?
        do {
            for key in accounts {
                guard try read(key, service: service).isEmpty else { throw AuroraKeychainMigrationError.refused }
            }
            for (key, accessibility) in zip(accounts, accessibilities) {
                var attributes = query(key, service: service)
                attributes[kSecAttrAccessible as String] = accessibility
                attributes[kSecValueData as String] = Data("aurora-public-default-acl-v1".utf8)
                try api.add(attributes)
                created.insert(key)
                let item = try binding(key, service: service)
                guard item.accessibility == accessibility else { throw AuroraKeychainMigrationError.refused }
                bound[key] = item
                values[accessibility] = item
            }
            if exercise {
                guard bound["legacy"]!.group == bound["background"]!.group else { throw AuroraKeychainMigrationError.refused }
                var current = bound["legacy"]!
                for target in [Self.background, Self.legacy] {
                // Re-check ownership immediately before each dummy mutation.
                let before = try binding("legacy", service: service)
                guard before.group == current.group, before.accessibility == current.accessibility,
                      CFEqual(before.control, current.control) else { throw AuroraKeychainMigrationError.refused }
                try api.update(exactQuery("legacy", service: service, binding: current),
                               attributes: [kSecAttrAccessible as String: target])
                let after = try binding("legacy", service: service)
                guard after.accessibility == target,
                      try Baselines(values: values).matches(after.control, accessibility: target, group: after.group) else {
                    throw AuroraKeychainMigrationError.refused
                }
                current = after
                }
            }
        } catch { operationError = error }

        // One bounded cleanup pass. An Add-success without a trustworthy
        // readback binding is retained for explicit recovery, never guessed at.
        var cleanupComplete = true
        for key in accounts where created.contains(key) {
            do {
                guard let original = bound[key] else { throw AuroraKeychainMigrationError.refused }
                let current = try binding(key, service: service)
                guard current.group == original.group,
                      let expected = current.accessibility == original.accessibility ? original : values[current.accessibility],
                      CFEqual(current.control, expected.control) else { throw AuroraKeychainMigrationError.refused }
                try api.remove(exactQuery(key, service: service, binding: current))
                guard try read(key, service: service).isEmpty else { throw AuroraKeychainMigrationError.refused }
            } catch { cleanupComplete = false }
        }
        guard cleanupComplete else { throw AuroraKeychainMigrationError.defaultACLCleanup }
        try journal.completed()
        if let operationError { throw operationError }
        guard values.count == accessibilities.count else { throw AuroraKeychainMigrationError.refused }
        return Baselines(values: values)
    }
}

final class AuroraSystemDefaultACLAPI: AuroraKeychainDefaultACLAPI {
    private let attributes = AuroraSystemKeychainAPI()
    private func nonInteractive(_ query: [String: Any]) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = query
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]] { try attributes.copyMatching(query) }
    func update(_ query: [String: Any], attributes: [String: Any]) throws { try self.attributes.update(query, attributes: attributes) }
    func add(_ attributes: [String: Any]) throws {
        let status = SecItemAdd(nonInteractive(attributes) as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuroraKeychainMigrationError.security(status) }
    }
    func remove(_ query: [String: Any]) throws {
        let status = SecItemDelete(nonInteractive(query) as CFDictionary)
        guard status == errSecSuccess else { throw AuroraKeychainMigrationError.security(status) }
    }
}

enum AuroraSystemDefaultACLFactory {
    private static func qualification() throws -> AuroraKeychainDefaultACLQualification {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let journal = AuroraKeychainFileNamespaceJournal(
            directory: support.appendingPathComponent("Aurora-KeychainQualification", isDirectory: true))
        return AuroraKeychainDefaultACLQualification(api: AuroraSystemDefaultACLAPI(), journal: journal)
    }
    static func qualify() throws -> AuroraKeychainDefaultACLProvider {
        try qualification().run(namespace: UUID().uuidString.lowercased())
    }
    static func provider() throws -> AuroraKeychainDefaultACLProvider {
        // No legacy seed on an already-migrated cold start. The caller holds
        // this object for one serialized migration/rollback invocation only.
        AuroraKeychainLazyDefaultACLProvider { accessibility in
            try qualification().seed(namespace: UUID().uuidString.lowercased(), accessibility: accessibility)
        }
    }
}
