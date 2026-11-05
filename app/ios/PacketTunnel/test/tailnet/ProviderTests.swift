import Foundation
import CryptoKit
import Darwin

@main private struct TailnetProviderTests {
    static func options(_ prepared: AuroraTailnetStore.Prepared, _ json: String) -> [String: NSObject] {
        ["tailnetSettingsGeneration": NSNumber(value: prepared.settingsGeneration),
         "tailnetNodeGeneration": prepared.nodeGeneration as NSString,
         "tailnetConfigSHA256": SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined() as NSString]
    }
    static func request(_ provider: PacketTunnelProvider, _ body: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            provider.handleAppMessage(try! JSONSerialization.data(withJSONObject: body)) { data in
                continuation.resume(returning: data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:])
            }
        }
    }
    static func wait(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success) }
        }
    }
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let store = AuroraTailnetStore(container: Harness.directory), provider = PacketTunnelProvider()
        _ = try store.setEnabled(0, true, requireStopped: { true })
        let prepared = try store.prepareStart(1)!
        let json = String(data: try JSONSerialization.data(withJSONObject: publicTailnetConfig(prepared)), encoding: .utf8)!
        try json.write(to: Harness.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        var admission = options(prepared, json), failures = [String]()
        func expect(_ value: Bool, _ text: String) { if !value { failures.append(text) } }
        if scenario == "stale-generation" { _ = try store.setEnabled(1, false, requireStopped: { true }) }
        if scenario == "wrong-digest" { admission["tailnetConfigSHA256"] = String(repeating: "0", count: 64) as NSString }
        if scenario == "wrong-node" { admission["tailnetNodeGeneration"] = UUID().uuidString as NSString }
        if scenario == "boolean-generation" { admission["tailnetSettingsGeneration"] = NSNumber(value: true) }
        if scenario == "extra-options" { admission["unknown"] = "public-fixture" as NSString }
        let shouldReject = ["stale-generation", "wrong-digest", "wrong-node", "boolean-generation", "extra-options", "ordinary-start-with-tailnet"].contains(scenario)
        if scenario == "setup-error-safe" { Harness.failSetup = true }
        if scenario == "allocation-error-safe" { Harness.failAllocation = true }
        var rejected = false, failureDetail = ""
        do { try await provider.startTunnel(options: scenario == "ordinary-start-with-tailnet" ? nil : admission) }
        catch { rejected = true; failureDetail = error.localizedDescription }
        if scenario == "setup-error-safe" || scenario == "allocation-error-safe" {
            expect(rejected && Harness.servers.isEmpty, "setup/allocation failure rejects before core allocation")
            expect(!failureDetail.contains("PUBLIC_AUTH_ERROR_MARKER"), "native start failure does not disclose raw library error")
            let diagnostic = (try? String(contentsOf: Harness.directory.appendingPathComponent("diag.log"), encoding: .utf8)) ?? ""
            expect(!diagnostic.contains("PUBLIC_AUTH_ERROR_MARKER"), "native start diagnostics do not disclose raw library error")
            expect(try store.forget(prepared.nodeGeneration, requireStopped: { true }) == "forgotten", "pre-allocation failure releases lease")
        } else if shouldReject {
            expect(rejected, "invalid Tailnet admission must fail")
            expect(Harness.servers.isEmpty, "invalid Tailnet admission must fail before allocating core")
        } else {
            expect(!rejected && Harness.servers.first?.coreStarts == 1, "valid native Tailnet context reaches one core")
            if scenario == "lease-held" {
                let forgotten = try store.forget(prepared.nodeGeneration, requireStopped: { true })
                expect(forgotten == "busy", "running core retains cross-process identity lease even if host reports stopped")
            }
            if scenario.hasPrefix("reload-") {
                let initial = await request(provider, ["method": "sessionSnapshot"])
                let token = initial["sessionId"] as? String ?? ""
                let oldPlatform = Harness.platforms[0]
                if scenario == "reload-close-error" { Harness.failCloseService = true }
                if scenario == "reload-stop-during-create" { Harness.blockServerCreation = true }
                let reload = Task { await request(provider, ["method": "reloadCurrentSession", "sessionId": token]) }
                if scenario == "reload-stop-during-create" {
                    let entered = await wait(Harness.serverCreationEntered)
                    expect(entered, "reload allocates a fresh command server")
                    let stop = Task { await provider.stopTunnel(with: .userInitiated) }
                    for _ in 0..<100 {
                        let status = await request(provider, ["method": "sessionSnapshot"])
                        if status["status"] as? String == "disconnected" { break }
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    expect(try store.forget(prepared.nodeGeneration, requireStopped: { true }) == "busy", "inflight replacement retains identity lease")
                    Harness.releaseServerCreation.signal()
                    await stop.value
                }
                let reply = await reload.value
                if scenario == "reload-close-error" {
                    expect(reply["result"] as? String == "requiresReconnect", "failed close rejects reload")
                    expect(TunnelProcessHealth.shared.isPoisoned && Harness.servers.count == 1, "failed close poisons without replacement allocation")
                    expect(try store.forget(prepared.nodeGeneration, requireStopped: { true }) == "busy", "failed reload close retains lease")
                    expect(Harness.servers[0].closeServiceCalls == 1, "uncertain close is not retried")
                } else if scenario == "reload-stop-during-create" {
                    expect(reply["result"] as? String == "unavailable", "stopped reload cannot regain session")
                    expect(Harness.servers.count == 2 && Harness.servers.last?.coreStarts == 0, "stop drains replacement allocation before any core start")
                    expect(Harness.servers.last?.closeCalls == 1, "unstarted replacement releases command observers")
                    expect(try store.forget(prepared.nodeGeneration, requireStopped: { true }) == "forgotten", "drained allocation releases identity lease")
                } else {
                    expect(reply["result"] as? String == "reloaded", "Tailnet reload succeeds")
                    expect(Harness.servers.count == 2 && Harness.servers[0].coreStarts == 1 && Harness.servers.last?.coreStarts == 1, "reload creates a new core/platform instead of reusing callback owner")
                    expect(Harness.servers[0].closeServiceCalls == 1 && Harness.servers[0].closeCalls == 1, "old core and listener close before replacement")
                    let after = await request(provider, ["method": "sessionSnapshot"])
                    expect(after["sessionId"] as? String == token, "Tailnet reload retains existing NE session UUID")
                    expect(try store.forget(prepared.nodeGeneration, requireStopped: { true }) == "busy", "reload retains same identity lease")
                    expect(!provider.canConfigureTunnel(oldPlatform.sessionID), "old platform loses network-settings permission")
                    provider.requestServiceStop(oldPlatform.sessionID)
                    let stillLive = await request(provider, ["method": "sessionSnapshot"])
                    expect(stillLive["sessionId"] as? String == token, "old serviceStop callback cannot stop replacement")
                    var refused = false
                    do { try provider.reloadService(oldPlatform.sessionID) } catch { refused = true }
                    expect(refused, "old serviceReload callback cannot reload replacement")
                }
            }
            if scenario == "close-throws-retains-lease" { Harness.failCloseService = true }
            await provider.stopTunnel(with: .userInitiated)
            if scenario == "close-throws-retains-lease" || scenario == "reload-close-error" {
                expect(TunnelProcessHealth.shared.isPoisoned, "uncertain close poisons process")
                expect(try store.forget(prepared.nodeGeneration, requireStopped: { true }) == "busy", "uncertain close retains identity lease")
            } else if scenario != "reload-stop-during-create" {
                expect(try store.forget(prepared.nodeGeneration, requireStopped: { true }) == "forgotten", "confirmed core close releases lease")
            }
        }
        for message in failures { print("FAIL \(scenario): \(message)") }
        if failures.isEmpty { print("PASS \(scenario)") }
        Darwin.exit(failures.isEmpty ? 0 : 1)
    }
}
