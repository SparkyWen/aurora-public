import Foundation
import Security
import LocalAuthentication
import Darwin

protocol AuroraKeychainAPI {
    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]]
    func update(_ query: [String: Any], attributes: [String: Any]) throws
}

struct AuroraKeychainReceipt: Codable, Equatable {
    struct Item: Codable, Equatable {
        let key: String
        let previousAccessibility: String?
        let accessGroup: String?
    }
    let schema: Int
    let service: String
    let items: [Item]
}

protocol AuroraKeychainReceiptStore {
    func lock() throws
    func unlock()
    func load() throws -> AuroraKeychainReceipt?
    func create(_ receipt: AuroraKeychainReceipt) throws
}

enum AuroraKeychainObservationRefusal: String {
    case shape, identity, group, accessibility
    case accessControl = "access-control"
    case resultType = "result-type"
    case multipleMatches = "multiple-matches"
}

enum AuroraKeychainSchemaPresence: String, Hashable {
    case generic, invisible, negative, creator, type, permanent
    case tokenID = "token-id"
    case legacyAccess = "legacy-access"
    case applicationLabel = "application-label"
    case applicationTag = "application-tag"
    case unrecognizedPresent = "unrecognized-present"

    // Only public constant presence is classified. Unknown names are never
    // returned or persisted, even as hashes; no attribute value is inspected.
    static func classify(_ keys: Set<String>) -> [Self] {
        let known: [String: Self] = [
            kSecAttrGeneric as String: .generic, kSecAttrIsInvisible as String: .invisible,
            kSecAttrIsNegative as String: .negative, kSecAttrCreator as String: .creator,
            kSecAttrType as String: .type, kSecAttrTokenID as String: .tokenID,
            kSecAttrAccess as String: .legacyAccess, kSecAttrIsPermanent as String: .permanent,
            kSecAttrApplicationLabel as String: .applicationLabel,
            kSecAttrApplicationTag as String: .applicationTag]
        return Set(keys.map { known[$0] ?? .unrecognizedPresent }).sorted { $0.rawValue < $1.rawValue }
    }
}

enum AuroraKeychainMigrationError: Error {
    case security(OSStatus)
    case observation(AuroraKeychainObservationRefusal)
    case unknownAttributes([AuroraKeychainSchemaPresence])
    case refused
    case receipt
    case defaultACLCleanup
    case qualificationRequired
}

struct AuroraKeychainAccessibilityCounts {
    let legacy: Int
    let background: Int
    let absent: Int
}

final class AuroraKeychainMigration {
    static let keys = ["aurora_contract_json", "aurora_delivery_url", "aurora_mode",
                       "aurora_path_preference", "aurora_egress_lease_json",
                       "aurora_route_family", "aurora_egress_interface"]
    static let service = "flutter_secure_storage_service"
    private let api: AuroraKeychainAPI
    private let receipts: AuroraKeychainReceiptStore
    private let defaults: () throws -> AuroraKeychainDefaultACLProvider
    init(api: AuroraKeychainAPI, receipts: AuroraKeychainReceiptStore,
         defaults: @escaping () throws -> AuroraKeychainDefaultACLProvider) {
        self.api = api
        self.receipts = receipts
        self.defaults = defaults
    }
    private static let legacy = kSecAttrAccessibleWhenUnlocked as String
    private static let background = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    private static func query(_ key: String) -> [String: Any] {
        // Match only this app's seven accounts, within the plugin's unchanged
        // default access-group boundary. Never request keychain value data.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: key, kSecAttrService as String: Self.service,
         kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
    }

    private static func observe(_ key: String, api: AuroraKeychainAPI,
                                defaults: AuroraKeychainDefaultACLProvider? = nil) throws -> AuroraKeychainReceipt.Item {
        var q = query(key)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        let matches = try api.copyMatching(q)
        guard matches.count <= 1 else { throw AuroraKeychainMigrationError.observation(.multipleMatches) }
        guard let item = matches.first else {
            return .init(key: key, previousAccessibility: nil, accessGroup: nil)
        }
        // Ordinary item metadata is not persisted. Unknown attributes, opaque
        // access controls other than the default, and unexpected identity stop
        // migration before any item is changed.
        let allowed: Set<String> = [kSecClass, kSecAttrAccount, kSecAttrService,
            kSecAttrAccessible, kSecAttrAccessGroup, kSecAttrSynchronizable,
            kSecAttrCreationDate, kSecAttrModificationDate, kSecAttrLabel,
            kSecAttrDescription, kSecAttrComment, kSecAttrAccessControl].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        // Security also returns its user-view, digest and tombstone metadata.
        // Its normal query binds the caller's view and excludes tombstones.
        // Recognize only their presence; never inspect/copy values or change
        // the query/update boundary.
        let systemMetadata: Set<String> = ["musr", "sha1", "tomb"]
        let unknown = Set(item.keys).subtracting(allowed).subtracting(systemMetadata)
        guard unknown.isEmpty else {
            throw AuroraKeychainMigrationError.unknownAttributes(AuroraKeychainSchemaPresence.classify(unknown))
        }
        guard item[kSecAttrAccount as String] as? String == key,
              item[kSecAttrService as String] as? String == Self.service,
              item[kSecAttrSynchronizable as String] as? Bool == false else {
            throw AuroraKeychainMigrationError.observation(.identity)
        }
        guard let group = item[kSecAttrAccessGroup as String] as? String, !group.isEmpty else {
            throw AuroraKeychainMigrationError.observation(.group)
        }
        guard let accessible = item[kSecAttrAccessible as String] as? String,
              [Self.legacy, Self.background].contains(accessible) else {
            throw AuroraKeychainMigrationError.observation(.accessibility)
        }
        if let klass = item[kSecClass as String] {
            guard klass as? String == kSecClassGenericPassword as String else {
                throw AuroraKeychainMigrationError.observation(.identity)
            }
        }
        if let accessControl = item[kSecAttrAccessControl as String] {
            guard CFGetTypeID(accessControl as CFTypeRef) == SecAccessControlGetTypeID() else {
                throw AuroraKeychainMigrationError.observation(.accessControl)
            }
            let plain = SecAccessControlCreateWithFlags(nil, accessible as CFString, [], nil)
            if plain == nil || !CFEqual(accessControl as CFTypeRef, plain!) {
                guard let defaults else { throw AuroraKeychainMigrationError.qualificationRequired }
                guard try defaults.matches(accessControl as CFTypeRef, accessibility: accessible, group: group) else {
                    throw AuroraKeychainMigrationError.observation(.accessControl)
                }
            }
        }
        return .init(key: key, previousAccessibility: accessible, accessGroup: group)
    }

    // A point-in-time compatibility snapshot only. No receipt store is
    // constructed or accessed; the same observation gates guard migration.
    static func checkAccessibility(api: AuroraKeychainAPI,
                                   defaults: AuroraKeychainDefaultACLProvider? = nil) throws -> AuroraKeychainAccessibilityCounts {
        let current = try keys.map { try observe($0, api: api, defaults: defaults) }
        return .init(legacy: current.filter { $0.previousAccessibility == legacy }.count,
                     background: current.filter { $0.previousAccessibility == background }.count,
                     absent: current.filter { $0.previousAccessibility == nil }.count)
    }

    private func observe(_ key: String, defaults: AuroraKeychainDefaultACLProvider) throws -> AuroraKeychainReceipt.Item {
        try Self.observe(key, api: api, defaults: defaults)
    }

    private func validate(_ receipt: AuroraKeychainReceipt) throws {
        guard receipt.schema == 1, receipt.service == Self.service,
              receipt.items.map(\.key) == Self.keys else { throw AuroraKeychainMigrationError.receipt }
        for item in receipt.items {
            if let previous = item.previousAccessibility {
                guard [Self.legacy, Self.background].contains(previous),
                      let group = item.accessGroup, !group.isEmpty else { throw AuroraKeychainMigrationError.receipt }
            } else if item.accessGroup != nil { throw AuroraKeychainMigrationError.receipt }
        }
    }

    private func change(_ current: AuroraKeychainReceipt.Item, to accessibility: String,
                        defaults: AuroraKeychainDefaultACLProvider) throws {
        guard let old = current.previousAccessibility, old != accessibility else { return }
        var q = Self.query(current.key)
        q[kSecAttrAccessGroup as String] = current.accessGroup
        q[kSecAttrAccessible as String] = old
        try api.update(q, attributes: [kSecAttrAccessible as String: accessibility])
        let after = try observe(current.key, defaults: defaults)
        guard after.accessGroup == current.accessGroup, after.previousAccessibility == accessibility else {
            throw AuroraKeychainMigrationError.refused
        }
    }

    func prepare() throws {
        try receipts.lock()
        defer { receipts.unlock() }
        // Baselines are seeded on demand and held only for this invocation.
        // Attribute reads may discover a needed seed; every necessary cleanup
        // finishes before a receipt is created or production items are updated.
        let defaultACLs = try defaults()
        let current = try Self.keys.map { try observe($0, defaults: defaultACLs) }
        if current.contains(where: { $0.previousAccessibility != nil && $0.previousAccessibility != Self.background }) {
            try defaultACLs.prepare(accessibility: Self.background)
        }
        let receipt: AuroraKeychainReceipt
        if let saved = try receipts.load() {
            try validate(saved)
            receipt = saved
        } else {
            receipt = .init(schema: 1, service: Self.service, items: current)
            // The immutable plan survives partial migration; creation must be
            // durable before the first SecItemUpdate, including on retries.
            try receipts.create(receipt)
        }
        try checkGroups(current, receipt)
        for item in current { try change(item, to: Self.background, defaults: defaultACLs) }
    }

    private func checkGroups(_ current: [AuroraKeychainReceipt.Item], _ receipt: AuroraKeychainReceipt) throws {
        for (now, original) in zip(current, receipt.items) {
            if now.previousAccessibility != nil, let group = original.accessGroup,
               now.accessGroup != group { throw AuroraKeychainMigrationError.refused }
        }
    }

    // Explicit maintenance only: not registered on the Flutter channel and
    // never run at startup. Values created since migration are preserved too.
    func rollback() throws {
        try receipts.lock()
        defer { receipts.unlock() }
        try rollbackLocked()
    }

    func rollback(afterChecking admission: () async throws -> Void) async throws {
        try receipts.lock()
        defer { receipts.unlock() }
        try await admission()
        try rollbackLocked()
    }

    private func rollbackLocked() throws {
        guard let receipt = try receipts.load() else { throw AuroraKeychainMigrationError.receipt }
        try validate(receipt)
        let defaultACLs = try defaults()
        let current = try Self.keys.map { try observe($0, defaults: defaultACLs) }
        try checkGroups(current, receipt)
        if zip(current, receipt.items).contains(where: { now, original in
            now.previousAccessibility == Self.background && original.previousAccessibility != Self.background
        }) {
            try defaultACLs.prepare(accessibility: Self.legacy)
        }
        for (now, original) in zip(current, receipt.items) {
            if original.previousAccessibility != Self.background {
                try change(now, to: Self.legacy, defaults: defaultACLs)
            }
        }
    }
}

// A deliberately small, immutable receipt. Only this directory is accessed;
// the native maintenance caller can use the same store for explicit rollback.
final class AuroraKeychainFileReceiptStore: AuroraKeychainReceiptStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    deinit { unlock() }

    private func requirePrivate(_ fd: Int32, directory: Bool = false) throws {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o777 == (directory ? 0o700 : 0o600),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw AuroraKeychainMigrationError.receipt }
    }

    func lock() throws {
        guard directoryFD == -1 else { throw AuroraKeychainMigrationError.receipt }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw AuroraKeychainMigrationError.receipt }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        do { try requirePrivate(dir, directory: true) }
        catch { if dir >= 0 { close(dir) }; throw error }
        let fd = openat(dir, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        do {
            try requirePrivate(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AuroraKeychainMigrationError.receipt }
        } catch { if fd >= 0 { close(fd) }; close(dir); throw error }
        directoryFD = dir
        lockFD = fd
    }

    func unlock() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        if directoryFD >= 0 { close(directoryFD); directoryFD = -1 }
    }

    func load() throws -> AuroraKeychainReceipt? {
        guard lockFD >= 0 else { throw AuroraKeychainMigrationError.receipt }
        let fd = openat(directoryFD, "receipt.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd == -1 && errno == ENOENT { return nil }
        defer { if fd >= 0 { close(fd) } }
        try requirePrivate(fd)
        var bytes = [UInt8](repeating: 0, count: 16385)
        var count = 0
        while count < bytes.count {
            let length = bytes.count - count
            let amount = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: count), length) }
            if amount < 0 && errno == EINTR { continue }
            guard amount >= 0 else { throw AuroraKeychainMigrationError.receipt }
            if amount == 0 { break }
            count += amount
        }
        guard count > 0, count <= 16384, fsync(fd) == 0, fsync(directoryFD) == 0 else {
            throw AuroraKeychainMigrationError.receipt
        }
        do { return try JSONDecoder().decode(AuroraKeychainReceipt.self, from: Data(bytes.prefix(count))) }
        catch { throw AuroraKeychainMigrationError.receipt }
    }

    func create(_ receipt: AuroraKeychainReceipt) throws {
        guard lockFD >= 0 else { throw AuroraKeychainMigrationError.receipt }
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= 16384 else { throw AuroraKeychainMigrationError.receipt }
        let temporary = ".receipt-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        defer {
            if fd >= 0 { close(fd) }
            unlinkat(directoryFD, temporary, 0)
        }
        try requirePrivate(fd)
        var count = 0
        while count < data.count {
            let amount = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: count), data.count - count) }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw AuroraKeychainMigrationError.receipt }
            count += amount
        }
        // linkat publishes without overwriting an existing original receipt.
        guard fsync(fd) == 0,
              linkat(directoryFD, temporary, directoryFD, "receipt.json", 0) == 0,
              unlinkat(directoryFD, temporary, 0) == 0,
              fsync(directoryFD) == 0 else { throw AuroraKeychainMigrationError.receipt }
    }
}

final class AuroraSystemKeychainAPI: AuroraKeychainAPI {
    private func nonInteractive(_ query: [String: Any]) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = query
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    func copyMatching(_ query: [String: Any]) throws -> [[String: Any]] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(nonInteractive(query) as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw AuroraKeychainMigrationError.security(status) }
        guard let rows = result as? [[String: Any]] else { throw AuroraKeychainMigrationError.observation(.resultType) }
        return rows
    }

    func update(_ query: [String: Any], attributes: [String: Any]) throws {
        let status = SecItemUpdate(nonInteractive(query) as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw AuroraKeychainMigrationError.security(status) }
    }
}
