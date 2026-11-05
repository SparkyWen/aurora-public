import Foundation
import CoreFoundation

enum AuroraTailnetStoreFailure: String, Error {
    case storage, busy, stale
    case invalidState = "invalid-state"
}

final class AuroraTailnetStore {
    struct Settings: Equatable {
        let settingsGeneration: Int64
        let enabled: Bool
        let nodeGeneration: String?
        var channelValue: [String: Any] {
            ["schema": 1, "settingsGeneration": settingsGeneration, "enabled": enabled,
             "nodeGeneration": nodeGeneration as Any? ?? NSNull()]
        }
    }
    struct Prepared: Equatable {
        let settingsGeneration: Int64
        let nodeGeneration: String
        let stateDirectory: String
        let hostname: String
        var channelValue: [String: Any] {
            ["schema": 1, "settingsGeneration": settingsGeneration, "nodeGeneration": nodeGeneration,
             "stateDirectory": stateDirectory, "hostname": hostname]
        }
    }
    final class Lease {
        let prepared: Prepared
        let sessionID: String
        private let owner: AuroraTailnetFileLock
        fileprivate init(_ prepared: Prepared, _ sessionID: String, _ owner: AuroraTailnetFileLock) {
            self.prepared = prepared; self.sessionID = sessionID; self.owner = owner
        }
        // Only the native engine's confirmed close path may call this. A timeout
        // or a disconnected system status must retain the lease until exit.
        func closeAfterCoreClosed() { owner.close() }
    }
    private struct Record { var settings: Settings; var phase: String }
    private let files: AuroraTailnetStoreFiles
    // The native caller obtains this URL from its App Group, never from Dart.
    init(container: URL) { files = AuroraTailnetStoreFiles(container: container) }
    func readSettings() throws -> Settings { try safely { try read().settings } }
    func setEnabled(_ expected: Int64, _ enabled: Bool, requireStopped: () -> Bool) throws -> Settings {
        try locked {
            var record = try read()
            try requireExpected(record, expected)
            guard record.phase != "forgetting" else { throw AuroraTailnetStoreFailure.invalidState }
            guard requireStopped() else { throw AuroraTailnetStoreFailure.busy }
            if record.settings.enabled == enabled { return record.settings }
            record.settings = Settings(settingsGeneration: try increment(expected), enabled: enabled,
                nodeGeneration: record.settings.nodeGeneration)
            try write(record)
            return record.settings
        }
    }
    func prepareStart(_ expected: Int64) throws -> Prepared? {
        try locked {
            var record = try read()
            try requireExpected(record, expected)
            guard record.phase != "forgetting" else { throw AuroraTailnetStoreFailure.invalidState }
            guard record.settings.enabled else { return nil }
            if record.phase == "none" {
                record.settings = Settings(settingsGeneration: expected, enabled: true,
                    nodeGeneration: UUID().uuidString)
                record.phase = "allocated"
                try write(record)
            }
            if record.phase == "allocated" {
                try files.allocateNode(record.settings.nodeGeneration!)
                record.phase = "ready"
                try write(record)
            }
            return try context(record)
        }
    }
    func acquireSessionLease(_ prepared: Prepared, sessionID: String) throws -> Lease {
        try safely {
            try requireUUID(sessionID)
            let lock = try files.acquire()
            do {
                let record = try read()
                guard record.phase == "ready", record.settings.enabled,
                      try context(record) == prepared else { throw AuroraTailnetStoreFailure.stale }
                return Lease(prepared, sessionID, lock)
            } catch { lock.close(); throw error }
        }
    }
    func forget(_ nodeGeneration: String, requireStopped: () -> Bool) throws -> String {
        do {
            return try locked {
                try requireUUID(nodeGeneration)
                var record = try read()
                guard record.settings.nodeGeneration == nodeGeneration else { return "stale" }
                guard requireStopped() else { return "busy" }
                if record.phase != "forgetting" {
                    record.settings = Settings(settingsGeneration: try increment(record.settings.settingsGeneration),
                        enabled: false, nodeGeneration: nodeGeneration)
                    record.phase = "forgetting"
                    try write(record)
                }
                try files.removeNode(nodeGeneration)
                record.settings = Settings(settingsGeneration: record.settings.settingsGeneration,
                    enabled: false, nodeGeneration: nil)
                record.phase = "none"
                try write(record)
                return "forgotten"
            }
        } catch AuroraTailnetStoreFailure.busy { return "busy" }
    }
    private func context(_ record: Record) throws -> Prepared {
        guard let node = record.settings.nodeGeneration else { throw AuroraTailnetStoreFailure.invalidState }
        return Prepared(settingsGeneration: record.settings.settingsGeneration, nodeGeneration: node,
            stateDirectory: files.nodePath(node).path, hostname: "aurora-" + node.prefix(8).lowercased())
    }
    private func read() throws -> Record {
        var record = Record(settings: Settings(settingsGeneration: 0, enabled: false, nodeGeneration: nil), phase: "none")
        if let data = try files.readMetadata() {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["schema", "settingsGeneration", "enabled", "nodeGeneration", "phase"],
                  let schema = integer(object["schema"]), schema == 1,
                  let generation = integer(object["settingsGeneration"]), generation >= 0,
                  let enabled = object["enabled"] as? NSNumber,
                  CFGetTypeID(enabled) == CFBooleanGetTypeID(),
                  let phase = object["phase"] as? String,
                  ["none", "allocated", "ready", "forgetting"].contains(phase) else {
                throw AuroraTailnetStoreFailure.invalidState
            }
            let node: String?
            if object["nodeGeneration"] is NSNull { node = nil }
            else if let value = object["nodeGeneration"] as? String { try requireUUID(value); node = value }
            else { throw AuroraTailnetStoreFailure.invalidState }
            guard (node == nil) == (phase == "none"), phase != "forgetting" || !enabled.boolValue else {
                throw AuroraTailnetStoreFailure.invalidState
            }
            record = Record(settings: Settings(settingsGeneration: generation, enabled: enabled.boolValue,
                nodeGeneration: node), phase: phase)
            // Canonical round trip also rejects duplicate JSON keys and coercion.
            guard encode(record) == data else { throw AuroraTailnetStoreFailure.invalidState }
        }
        try files.validateLayout(node: record.settings.nodeGeneration, phase: record.phase)
        return record
    }
    private func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["d", "f"].contains(String(cString: number.objCType)) else { return nil }
        return Int64(number.stringValue)
    }
    private func encode(_ record: Record) -> Data {
        let s = record.settings
        let node = s.nodeGeneration.map { "\"\($0)\"" } ?? "null"
        return Data("{\"schema\":1,\"settingsGeneration\":\(s.settingsGeneration),\"enabled\":\(s.enabled),\"nodeGeneration\":\(node),\"phase\":\"\(record.phase)\"}\n".utf8)
    }
    private func write(_ record: Record) throws { try files.writeMetadata(encode(record)) }
    private func requireExpected(_ record: Record, _ expected: Int64) throws {
        guard expected >= 0 else { throw AuroraTailnetStoreFailure.invalidState }
        guard record.settings.settingsGeneration == expected else { throw AuroraTailnetStoreFailure.stale }
    }
    private func increment(_ value: Int64) throws -> Int64 {
        guard value != Int64.max else { throw AuroraTailnetStoreFailure.invalidState }
        return value + 1
    }
    private func requireUUID(_ value: String) throws {
        guard value.utf8.count == 36,
            value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil else {
            throw AuroraTailnetStoreFailure.invalidState
        }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try safely { let lock = try files.acquire(); defer { lock.close() }; return try body() }
    }
    private func safely<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as AuroraTailnetStoreFailure { throw error }
        catch { throw AuroraTailnetStoreFailure.storage }
    }
}
