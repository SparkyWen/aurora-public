import Foundation
import Darwin

struct FailedExpectation: Error { var line: UInt = 0 }
func expect(_ value: @autoclosure () throws -> Bool, line: UInt = #line) throws {
    if try !value() { throw FailedExpectation(line: line) }
}
func expectError(_ expected: AuroraTailnetStoreFailure, _ body: () throws -> Void) throws {
    do { try body(); throw FailedExpectation() }
    catch let failure as AuroraTailnetStoreFailure { try expect(failure == expected) }
}
let session = "09091A98-9FE3-4A16-8FAA-C9A78D05EF75"

@main struct StoreTests {
    static func main() throws {
        if CommandLine.arguments.count > 2 {
            let store = AuroraTailnetStore(container: URL(fileURLWithPath: CommandLine.arguments[2]))
            let value = try store.readSettings()
            if CommandLine.arguments[1] == "acquire-and-exit" {
                let prepared = try store.prepareStart(value.settingsGeneration)!
                _ = try store.acquireSessionLease(prepared, sessionID: session)
                print("held-until-exit")
                return
            }
            let result = try store.forget(value.nodeGeneration!, requireStopped: { true })
            print(result)
            return
        }
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AURORA_TAILNET_TEST_ROOT"]!)
        var failures = 0
        func test(_ name: String, _ body: (AuroraTailnetStore, URL) throws -> Void) {
            do {
                let root = base.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                try body(AuroraTailnetStore(container: root), root)
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name) \(type(of: error)) line=\((error as? FailedExpectation)?.line ?? 0)")
            }
        }
        func enabled(_ store: AuroraTailnetStore) throws -> AuroraTailnetStore.Prepared {
            let settings = try store.setEnabled(0, true, requireStopped: { true })
            return try store.prepareStart(settings.settingsGeneration)!
        }
        func metadata(_ root: URL) -> URL { root.appendingPathComponent("aurora-tailnet/settings.json") }
        func raw(_ root: URL, _ content: String) throws {
            try content.write(to: metadata(root), atomically: false, encoding: .utf8)
        }
        test("initial-disabled-no-state") { store, root in
            try expect(store.readSettings() == .init(settingsGeneration: 0, enabled: false, nodeGeneration: nil))
            try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("aurora-tailnet").path))
            try expect(store.prepareStart(0) == nil)
        }
        test("enabled-idempotent") { store, _ in
            try expect(store.setEnabled(0, true, requireStopped: { true }).settingsGeneration == 1)
            try expect(store.setEnabled(1, true, requireStopped: { true }).settingsGeneration == 1)
            try expectError(.stale) { _ = try store.setEnabled(0, false, requireStopped: { true }) }
        }
        test("stop-admission-required") { store, _ in
            try expectError(.busy) { _ = try store.setEnabled(0, true, requireStopped: { false }) }
            try expect(store.readSettings().settingsGeneration == 0)
        }
        test("identity-persists-and-disables") { store, root in
            let first = try enabled(store)
            try expect(UUID(uuidString: first.nodeGeneration) != nil)
            try expect(first == AuroraTailnetStore(container: root).prepareStart(1))
            try expect(first.stateDirectory.hasPrefix(root.resolvingSymlinksInPath().path + "/aurora-tailnet/node-"))
            try expect(store.setEnabled(1, false, requireStopped: { true }).nodeGeneration == first.nodeGeneration)
            try expect(store.prepareStart(2) == nil)
        }
        test("lease-stale-and-lifetime") { store, _ in
            let value = try enabled(store)
            let lease = try store.acquireSessionLease(value, sessionID: session)
            try expectError(.busy) { _ = try store.prepareStart(1) }
            try expect(try store.forget(value.nodeGeneration, requireStopped: { true }) == "busy")
            try expect(store.readSettings().enabled)
            lease.closeAfterCoreClosed(); lease.closeAfterCoreClosed()
            try expect(try store.forget(value.nodeGeneration, requireStopped: { true }) == "forgotten")
            try expectError(.stale) { _ = try store.acquireSessionLease(value, sessionID: session) }
        }
        test("bad-session-cannot-lock") { store, _ in
            let value = try enabled(store)
            try expectError(.invalidState) { _ = try store.acquireSessionLease(value, sessionID: "bad") }
            let lease = try store.acquireSessionLease(value, sessionID: session)
            lease.closeAfterCoreClosed()
        }
        test("forget-stale-and-manual-stop") { store, _ in
            let value = try enabled(store)
            try expect(store.forget(session, requireStopped: { true }) == "stale")
            try expect(store.forget(value.nodeGeneration, requireStopped: { false }) == "busy")
            try expect(store.readSettings().nodeGeneration == value.nodeGeneration)
        }
        test("ready-directory-never-recreated") { store, _ in
            let value = try enabled(store)
            try FileManager.default.removeItem(atPath: value.stateDirectory)
            try expectError(.invalidState) { _ = try store.prepareStart(1) }
            try expect(!FileManager.default.fileExists(atPath: value.stateDirectory))
        }
        test("orphan-state-refused") { store, root in
            _ = try enabled(store)
            try FileManager.default.removeItem(at: metadata(root))
            try expectError(.invalidState) { _ = try store.prepareStart(0) }
        }
        for (name, replacement) in [
            ("unknown-schema", "\"schema\":2"),
            ("negative-generation", "\"settingsGeneration\":-1"),
            ("float-generation", "\"settingsGeneration\":1.0"),
            ("overflow-generation", "\"settingsGeneration\":9223372036854775808")
        ] {
            test(name) { store, root in
                _ = try enabled(store)
                let old = try String(contentsOf: metadata(root), encoding: .utf8)
                let field = name == "unknown-schema" ? "\"schema\":1" : "\"settingsGeneration\":1"
                try raw(root, old.replacingOccurrences(of: field, with: replacement))
                try expectError(.invalidState) { _ = try store.readSettings() }
            }
        }
        test("generation-max-no-wrap") { store, root in
            _ = try enabled(store)
            let old = try String(contentsOf: metadata(root), encoding: .utf8)
            try raw(root, old.replacingOccurrences(of: "\"settingsGeneration\":1", with: "\"settingsGeneration\":9223372036854775807"))
            try expect(store.readSettings().settingsGeneration == Int64.max)
            try expectError(.invalidState) { _ = try store.setEnabled(Int64.max, false, requireStopped: { true }) }
            try expect(store.readSettings().enabled)
        }
        test("uppercase-node-preserved") { store, root in
            let value = try enabled(store)
            let old = try String(contentsOf: metadata(root), encoding: .utf8)
            let upper = value.nodeGeneration.uppercased()
            try FileManager.default.moveItem(atPath: value.stateDirectory, toPath:
                root.appendingPathComponent("aurora-tailnet/node-" + upper).path)
            try raw(root, old.replacingOccurrences(of: value.nodeGeneration, with: upper))
            try expect(store.prepareStart(1)?.nodeGeneration == upper)
        }
        test("node-symlink-refused") { store, _ in
            let value = try enabled(store)
            try FileManager.default.removeItem(atPath: value.stateDirectory)
            try FileManager.default.createSymbolicLink(atPath: value.stateDirectory, withDestinationPath: "/tmp")
            try expectError(.invalidState) { _ = try store.prepareStart(1) }
        }
        test("allocated-directory-interruption-resumes-same-node") { store, root in
            let value = try enabled(store)
            let old = try String(contentsOf: metadata(root), encoding: .utf8)
            try raw(root, old.replacingOccurrences(of: "\"phase\":\"ready\"", with: "\"phase\":\"allocated\""))
            try FileManager.default.removeItem(atPath: value.stateDirectory)
            try FileManager.default.createDirectory(atPath: value.stateDirectory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try expect(store.prepareStart(1) == value)
        }
        test("allocated-existing-core-state-never-adopted") { store, root in
            let value = try enabled(store)
            let old = try String(contentsOf: metadata(root), encoding: .utf8)
            try raw(root, old.replacingOccurrences(of: "\"phase\":\"ready\"", with: "\"phase\":\"allocated\""))
            try Data("fixture".utf8).write(to: URL(fileURLWithPath: value.stateDirectory).appendingPathComponent("tailscaled.state"))
            try expectError(.invalidState) { _ = try store.prepareStart(1) }
        }
        test("forget-failure-keeps-tombstone-and-can-resume") { store, root in
            let value = try enabled(store)
            let malicious = URL(fileURLWithPath: value.stateDirectory).appendingPathComponent("symlink")
            try FileManager.default.createSymbolicLink(atPath: malicious.path, withDestinationPath: "/tmp")
            try expectError(.invalidState) { _ = try store.forget(value.nodeGeneration, requireStopped: { true }) }
            try expect(store.readSettings().enabled == false)
            try expect(store.readSettings().settingsGeneration == 2)
            try expectError(.invalidState) { _ = try store.prepareStart(2) }
            try expectError(.invalidState) { _ = try store.setEnabled(2, true, requireStopped: { true }) }
            try FileManager.default.removeItem(at: malicious)
            try expect(store.forget(value.nodeGeneration, requireStopped: { true }) == "forgotten")
            try expect(store.readSettings().settingsGeneration == 2)
        }
        test("duplicate-json-rejected") { store, root in
            _ = try enabled(store)
            let old = try String(contentsOf: metadata(root), encoding: .utf8)
            try raw(root, old.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1,\"schema\":1"))
            try expectError(.invalidState) { _ = try store.readSettings() }
        }
        test("metadata-hardlink-rejected") { store, root in
            _ = try enabled(store)
            try FileManager.default.linkItem(at: metadata(root), to: root.appendingPathComponent("linked.json"))
            try expectError(.invalidState) { _ = try store.readSettings() }
        }
        test("special-mode-rejected") { store, root in
            _ = try enabled(store)
            try expect(chmod(metadata(root).path, 0o4600) == 0)
            try expectError(.invalidState) { _ = try store.readSettings() }
        }
        test("real-cross-process-lease") { store, root in
            let value = try enabled(store)
            let lease = try store.acquireSessionLease(value, sessionID: session)
            func child() throws -> String {
                let process = Process(); let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = ["forget", root.path]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { process.terminate(); throw FailedExpectation() }
                try expect(process.terminationStatus == 0)
                return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try expectError(.busy) { _ = try store.acquireSessionLease(value, sessionID: UUID().uuidString) }
            try expectError(.busy) { _ = try AuroraTailnetStore(container: root).prepareStart(1) }
            try expect(child() == "busy")
            lease.closeAfterCoreClosed()
            try expect(child() == "forgotten")
            try expect(store.readSettings().nodeGeneration == nil)
        }
        test("dropped-uncertain-lease-stays-owned-until-process-exit") { store, _ in
            let value = try enabled(store)
            weak var discarded: AuroraTailnetStore.Lease?
            try autoreleasepool {
                let lease = try store.acquireSessionLease(value, sessionID: session)
                discarded = lease
            }
            try expect(discarded == nil)
            try expect(store.forget(value.nodeGeneration, requireStopped: { true }) == "busy")
        }
        test("kernel-releases-exited-owner") { store, root in
            let value = try enabled(store)
            let child = Process(); let pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["acquire-and-exit", root.path]
            child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            try child.run()
            let deadline = Date().addingTimeInterval(3)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { child.terminate(); throw FailedExpectation() }
            try expect(child.terminationStatus == 0)
            try expect(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "held-until-exit\n")
            let lease = try store.acquireSessionLease(value, sessionID: session)
            lease.closeAfterCoreClosed()
        }
        Darwin.exit(failures == 0 ? 0 : 1)
    }
}
