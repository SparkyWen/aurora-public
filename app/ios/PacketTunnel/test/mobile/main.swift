import Foundation
import Darwin

@main struct MobileSessionTests {
    static func awaitReloadEntry() async -> Bool {
        await wait(Harness.reloadEntered)
    }
    static func wait(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
            }
        }
    }
    static func request(_ provider: PacketTunnelProvider, _ body: [String: Any]) async -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return await withCheckedContinuation { continuation in
            provider.handleAppMessage(data) { reply in
                let parsed = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                continuation.resume(returning: parsed ?? [:])
            }
        }
    }
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let provider = PacketTunnelProvider()
        try "{\"inbounds\":[]}".write(to: Harness.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        let absent = await request(provider, ["method": "sessionSnapshot"])
        expect(absent["sessionId"] == nil, "stopped provider has no recoverable session")
        if scenario == "stop-during-create" {
            Harness.blockServerCreation = true
            let start = Task { try await provider.startTunnel(options: nil) }
            let entered = await wait(Harness.serverCreationEntered)
            expect(entered, "start reaches native server allocation")
            await provider.stopTunnel(with: .userInitiated)
            Harness.releaseServerCreation.signal()
            var cancelled = false
            do { try await start.value } catch { cancelled = true }
            expect(cancelled, "stop invalidates initial start intent")
            expect(Harness.servers.first?.coreStarts == 0, "cancelled initial intent never starts core")
            expect(Harness.servers.first?.closeCalls == 1, "cancelled allocated server releases its observers")
            for failure in failures { print("FAIL \(scenario): \(failure)") }
            if failures.isEmpty { print("PASS \(scenario)") }
            Darwin.exit(failures.isEmpty ? 0 : 1)
        }
        try await provider.startTunnel(options: nil)
        let snapshot = await request(provider, ["method": "sessionSnapshot"])
        let token = snapshot["sessionId"] as? String ?? ""
        expect(!token.isEmpty && snapshot["status"] as? String == "connected", "running provider exposes opaque current-session token")
        let server = Harness.servers[0]
        if scenario == "healthy" || scenario == "session-config" {
            if scenario == "session-config" {
                try "{\"inbounds\":[],\"newManualConfig\":true}".write(to: Harness.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            }
            let reply = await request(provider, ["method": "reloadCurrentSession", "sessionId": token])
            expect(reply["result"] as? String == "reloaded", "current session reload succeeds")
            expect(server.coreStarts == 2 && Harness.servers.count == 1, "reload reuses one command server")
            let after = await request(provider, ["method": "sessionSnapshot"])
            expect(after["sessionId"] as? String == token, "reload keeps the system session token")
            expect(server.configs.last == server.configs.first, "reload uses only the existing session config")
            await provider.stopTunnel(with: .userInitiated)
        } else if scenario == "stale" || scenario == "stale-service-stop" || scenario == "stale-dns-clear" {
            let reply = await request(provider, ["method": "reloadCurrentSession", "sessionId": "old-session"])
            expect(reply["result"] as? String == "unavailable", "unknown token cannot reload")
            expect(server.coreStarts == 1, "stale token performs no native reload")
            await provider.stopTunnel(with: .userInitiated)
            let stopped = await request(provider, ["method": "reloadCurrentSession", "sessionId": token])
            expect(stopped["result"] as? String == "unavailable", "stopped session cannot revive")
            try await provider.startTunnel(options: nil)
            let next = await request(provider, ["method": "sessionSnapshot"])
            expect(next["sessionId"] as? String != token, "explicit replacement has a different UUID")
            let late = await request(provider, ["method": "reloadCurrentSession", "sessionId": token])
            expect(late["result"] as? String == "unavailable", "old token cannot reload new manual session")
            expect(Harness.servers[1].coreStarts == 1, "replacement is untouched by stale request")
            if scenario == "stale-dns-clear" {
                Harness.platforms[0].clearDNSCache()
                expect(Harness.tunnelSettingsChanges == 0, "retired DNS callback cannot alter replacement network settings")
            }
            if scenario == "stale-service-stop" {
                try Harness.platforms[0].serviceStop()
                try await Task.sleep(nanoseconds: 100_000_000)
                let live = await request(provider, ["method": "sessionSnapshot"])
                expect(live["sessionId"] as? String == next["sessionId"] as? String, "retired platform callback cannot stop replacement")
                expect(Harness.servers[1].closeCalls == 0, "retired platform callback does not close replacement core")
            }
            await provider.stopTunnel(with: .userInitiated)
        } else if scenario == "failure" {
            Harness.failReload = true
            var retirementClaimedAtCleanup = false
            Harness.beforeServiceClose = { retirementClaimedAtCleanup = TunnelProcessHealth.shared.isRestartPending }
            let reply = await request(provider, ["method": "reloadCurrentSession", "sessionId": token])
            expect(retirementClaimedAtCleanup, "failure must reserve process retirement before asynchronous cleanup releases admission")
            expect(reply["result"] as? String == "requiresReconnect", "engine reload failure requires explicit reconnect")
            expect(Harness.cancelledTunnels == 1, "failed core stops routing into failed tunnel")
            let after = await request(provider, ["method": "sessionSnapshot"])
            expect(after["sessionId"] == nil, "failed session loses recovery permission")
            var restartRefused = false
            do { try await provider.startTunnel(options: nil) } catch { restartRefused = true }
            expect(restartRefused && Harness.servers.count == 1,
                   "process scheduled to retire cannot start a new session just before exit")
        } else if scenario == "timeout" {
            Harness.blockReload = true
            let began = Date()
            let reply = await request(provider, ["method": "reloadCurrentSession", "sessionId": token])
            expect(reply["result"] as? String == "requiresReconnect", "wedged reload returns explicit reconnect within a bound")
            expect(Date().timeIntervalSince(began) < 24, "reload and cleanup deadlines are bounded")
            expect(TunnelProcessHealth.shared.isPoisoned, "timed-out core poisons its process")
            var refused = false
            do { try await provider.startTunnel(options: nil) } catch { refused = true }
            expect(refused && Harness.servers.count == 1, "poisoned process cannot create another core")
            Harness.releaseReload.signal()
        } else if scenario == "stop-during-reload" || scenario == "duplicate-reload" {
            Harness.blockReload = true
            let reload = Task { await request(provider, ["method": "reloadCurrentSession", "sessionId": token]) }
            let entered = await awaitReloadEntry()
            expect(entered, "reload reaches actual core boundary")
            if scenario == "duplicate-reload" {
                let busy = await request(provider, ["method": "sessionSnapshot"])
                expect(busy["status"] as? String == "connecting", "busy core is not reported ready for telemetry")
                let duplicate = await request(provider, ["method": "reloadCurrentSession", "sessionId": token])
                expect(duplicate["result"] as? String == "unavailable", "overlapping reload cannot start another core operation")
                expect(server.coreStarts == 2, "only one native reload is in flight")
                Harness.releaseReload.signal()
                let reply = await reload.value
                expect(reply["result"] as? String == "reloaded", "original reload finishes normally")
                await provider.stopTunnel(with: .userInitiated)
                for failure in failures { print("FAIL \(scenario): \(failure)") }
                if failures.isEmpty { print("PASS \(scenario)") }
                Darwin.exit(failures.isEmpty ? 0 : 1)
            }
            if entered {
                let stop = Task { await provider.stopTunnel(with: .userInitiated) }
                for _ in 0..<100 {
                    let state = await request(provider, ["method": "sessionSnapshot"])
                    if state["sessionId"] == nil { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                Harness.releaseReload.signal()
                await stop.value
            } else { Harness.releaseReload.signal() }
            let reply = await reload.value
            expect(reply["result"] as? String == "unavailable", "late reload result cannot claim stopped session connected")
            expect(Harness.servers.count == 1, "external stop never creates a new native server")
        }
        for failure in failures { print("FAIL \(scenario): \(failure)") }
        if failures.isEmpty { print("PASS \(scenario)") }
        Darwin.exit(failures.isEmpty ? 0 : 1)
    }
}
