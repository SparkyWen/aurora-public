import Foundation
import Darwin

final class AuroraTailnetFileLock {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func close() {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }
    // Intentionally no deinit unlock: an accidentally dropped uncertain core
    // lease must stay locked until process exit, rather than permit a new owner.
}

final class AuroraTailnetStoreFiles {
    private let base: URL
    private let root: URL
    private let metadata: URL
    private let pending: URL
    private let manager = FileManager.default
    init(container: URL) {
        base = container.resolvingSymlinksInPath().standardizedFileURL
        root = base.appendingPathComponent("aurora-tailnet", isDirectory: true)
        metadata = root.appendingPathComponent("settings.json")
        pending = root.appendingPathComponent("settings.next")
    }
    func acquire() throws -> AuroraTailnetFileLock {
        try checkDirectory(base, owned: false)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw AuroraTailnetStoreFailure.storage }
        try checkDirectory(root, checkProtection: false)
        // A crash before protecting a newly made empty root is resumable.
        if try children(root).isEmpty { try protect(root, excluded: true) }
        try checkDirectory(root)
        try syncDirectory(base)
        let path = root.appendingPathComponent("owner.lock")
        if let info = try statAt(path) { try checkFile(info) }
        var fd = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let created = fd >= 0
        if fd < 0 && errno == EEXIST { fd = open(path.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw AuroraTailnetStoreFailure.storage }
        do {
            try checkFile(try descriptorStat(fd))
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                throw errno == EWOULDBLOCK ? AuroraTailnetStoreFailure.busy : .storage
            }
            if created {
                try protect(path, excluded: false)
                guard fsync(fd) == 0 else { throw AuroraTailnetStoreFailure.storage }
                try syncDirectory(root)
            } else { try checkProtection(path, excluded: false) }
            return AuroraTailnetFileLock(fd)
        } catch { _ = Darwin.close(fd); throw error }
    }
    func readMetadata() throws -> Data? {
        guard try statAt(root) != nil else { return nil }
        try checkDirectory(root)
        guard let info = try statAt(metadata) else { return nil }
        try checkFile(info)
        try checkProtection(metadata, excluded: false)
        let fd = open(metadata.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AuroraTailnetStoreFailure.storage }
        defer { _ = Darwin.close(fd) }
        try checkFile(try descriptorStat(fd))
        var bytes = [UInt8](repeating: 0, count: 4097)
        var used = 0
        while used < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: used), $0.count - used) }
            if count < 0 { if errno == EINTR { continue }; throw AuroraTailnetStoreFailure.storage }
            if count == 0 { break }
            used += count
        }
        guard used <= 4096 else { throw AuroraTailnetStoreFailure.invalidState }
        return Data(bytes.prefix(used))
    }
    func validateLayout(node: String?, phase: String) throws {
        guard try statAt(root) != nil else {
            if node != nil { throw AuroraTailnetStoreFailure.invalidState }
            return
        }
        try checkDirectory(root)
        for entry in try children(root) {
            if ["owner.lock", "settings.json", "settings.next"].contains(entry.lastPathComponent) {
                guard let info = try statAt(entry) else { throw AuroraTailnetStoreFailure.invalidState }
                try checkFile(info)
            } else if let node, entry.lastPathComponent == "node-" + node {
                try checkDirectory(entry, checkProtection: phase != "allocated")
                if phase == "allocated", try !children(entry).isEmpty { throw AuroraTailnetStoreFailure.invalidState }
            }
            else { throw AuroraTailnetStoreFailure.invalidState }
        }
        if let node, phase == "ready" { try checkDirectory(nodePath(node)) }
    }
    func nodePath(_ node: String) -> URL { root.appendingPathComponent("node-" + node, isDirectory: true) }
    func allocateNode(_ node: String) throws {
        let directory = nodePath(node)
        if try statAt(directory) == nil {
            guard mkdir(directory.path, 0o700) == 0 else { throw AuroraTailnetStoreFailure.storage }
        }
        try checkDirectory(directory, checkProtection: false)
        guard try children(directory).isEmpty else { throw AuroraTailnetStoreFailure.invalidState }
        try protect(directory, excluded: true)
        try checkDirectory(directory)
        try syncDirectory(root)
    }
    func writeMetadata(_ data: Data) throws {
        try checkDirectory(root)
        if let info = try statAt(pending) {
            try checkFile(info)
            guard unlink(pending.path) == 0 else { throw AuroraTailnetStoreFailure.storage }
        }
        let fd = open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AuroraTailnetStoreFailure.storage }
        defer { _ = Darwin.close(fd) }
        try checkFile(try descriptorStat(fd))
        try protect(pending, excluded: false)
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: written), $0.count - written) }
            if count < 0 { if errno == EINTR { continue }; throw AuroraTailnetStoreFailure.storage }
            guard count > 0 else { throw AuroraTailnetStoreFailure.storage }
            written += count
        }
        guard fsync(fd) == 0, rename(pending.path, metadata.path) == 0 else { throw AuroraTailnetStoreFailure.storage }
        try syncDirectory(root)
        try checkProtection(metadata, excluded: false)
    }
    func removeNode(_ node: String) throws {
        let directory = nodePath(node)
        guard try statAt(directory) != nil else { return }
        func remove(_ entry: URL) throws {
            guard let info = try statAt(entry) else { throw AuroraTailnetStoreFailure.invalidState }
            if info.st_mode & S_IFMT == S_IFDIR {
                try checkDirectory(entry)
                for child in try children(entry) { try remove(child) }
                guard rmdir(entry.path) == 0 else { throw AuroraTailnetStoreFailure.storage }
            } else {
                try checkFile(info)
                guard unlink(entry.path) == 0 else { throw AuroraTailnetStoreFailure.storage }
            }
        }
        try remove(directory)
        try syncDirectory(root)
    }
    private func children(_ directory: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
    }
    private func statAt(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw AuroraTailnetStoreFailure.storage
    }
    private func descriptorStat(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AuroraTailnetStoreFailure.storage }
        return info
    }
    private func checkDirectory(_ url: URL, owned: Bool = true, checkProtection: Bool = true) throws {
        guard let info = try statAt(url), info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              !owned || info.st_mode & 0o7777 == 0o700 else { throw AuroraTailnetStoreFailure.invalidState }
        if owned && checkProtection { try self.checkProtection(url, excluded: true) }
    }
    private func checkFile(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o7777 == 0o600 else { throw AuroraTailnetStoreFailure.invalidState }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AuroraTailnetStoreFailure.storage }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw AuroraTailnetStoreFailure.storage }
    }
    private func protect(_ url: URL, excluded: Bool) throws {
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        if excluded {
            var target = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        }
        try checkProtection(url, excluded: excluded)
    }
    private func checkProtection(_ url: URL, excluded: Bool) throws {
        #if os(iOS)
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication else {
            throw AuroraTailnetStoreFailure.invalidState
        }
        #endif
        if excluded {
            guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
                throw AuroraTailnetStoreFailure.invalidState
            }
        }
    }
}
