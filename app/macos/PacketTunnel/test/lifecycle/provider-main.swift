import Foundation
import Darwin

@main struct ProviderLifecycleTests {
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let provider = PacketTunnelProvider()
        try "{\"inbounds\":[]}".write(to: Harness.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        #if AURORA_TEST_MACOS
        if scenario == "stop-service-throws" {
            try await provider.startTunnel(options: nil)
            Harness.failCloseService = true
            await provider.stopService()
            expect(TunnelProcessHealth.shared.isPoisoned, "throwing stopService must poison the retained process")
            expect(Harness.servers[0].closeCalls == 0, "stopService retains its command listener")
            var refused = false
            do { try provider.reloadService() } catch { refused = true }
            expect(refused && Harness.servers[0].coreStarts == 1, "poisoned retained listener must not reload another core")
            for message in failures { print("FAIL \(scenario): \(message)") }
            if failures.isEmpty { print("PASS \(scenario)") }
            Darwin.exit(failures.isEmpty ? 0 : 1)
        }
        #endif
        if scenario == "close-throws" {
            try await provider.startTunnel(options: nil)
            Harness.failCloseService = true
            await provider.stopTunnel(with: .userInitiated)
            expect(TunnelProcessHealth.shared.isPoisoned, "throwing core close must poison its process, not count as successful close")
            expect(Harness.servers[0].closeCalls == 1, "listener cleanup still runs after core close throws")
            var refused = false
            do { try await provider.startTunnel(options: nil) } catch { refused = true }
            expect(refused && Harness.servers.count == 1, "uncertain close cannot admit a replacement core")
        } else if scenario == "stale-close-timeout" {
            try await provider.startTunnel(options: nil)
            Harness.blockFirstClose = true
            var refused = false
            do { try await provider.startTunnel(options: nil) } catch { refused = true }
            // Release the worker even when the assertion fails. Its original
            // deadline stays real: the harness does not replace runBounded.
            Harness.blockedClose.signal()
            expect(refused, "start must refuse a process poisoned while reclaiming its old server")
            expect(Harness.servers.count == 1, "a poisoned old close must not create a replacement server")
            expect(Harness.servers[0].closeCalls == 1, "old listener must still be released")
            expect(Harness.messages.filter { $0.contains("restarting extension process:") }.count == 1, "poison must request one process restart")
        } else {
            Harness.failListener = scenario == "listener-failure"
            Harness.failCore = scenario == "core-failure"
            var threw = false
            do { try await provider.startTunnel(options: nil) } catch { threw = true }
            let server = Harness.servers[0]
            if scenario == "healthy" {
                expect(!threw && server.coreStarts == 1, "healthy start must reach the core")
                await provider.stopTunnel(with: .userInitiated)
                expect(server.closeCalls == 1, "healthy stop must release its listener")
            } else {
                expect(threw, "injected startup error must reach the caller")
                expect(server.closeCalls == 1, "failed startup must release its command listener")
                expect(server.closeServiceCalls == 1, "failed startup must attempt bounded core cleanup")
                expect(Harness.resets == 1, "failed startup must reset its platform")
                expect(Harness.messages.filter { $0.contains("restarting extension process:") }.isEmpty, "fresh ordinary failure must not request process restart")
                await provider.stopTunnel(with: .userInitiated)
                expect(server.closeCalls == 1, "later stop must not release a failed server twice")
            }
        }
        for message in failures { print("FAIL \(scenario): \(message)") }
        if failures.isEmpty { print("PASS \(scenario)") }
        Darwin.exit(failures.isEmpty ? 0 : 1)
    }
}
