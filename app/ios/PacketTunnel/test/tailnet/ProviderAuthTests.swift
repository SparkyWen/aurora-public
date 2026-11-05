import Foundation
import CryptoKit
import Darwin

@main private struct ProviderAuthTests {
    static func request(_ provider: PacketTunnelProvider, _ body: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            provider.handleAppMessage(try! JSONSerialization.data(withJSONObject: body)) { data in
                continuation.resume(returning: data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:])
            }
        }
    }
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let store = AuroraTailnetStore(container: Harness.directory), provider = PacketTunnelProvider()
        if scenario == "ordinary-reloading" {
            try "{\"inbounds\":[]}".write(to: Harness.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            try await provider.startTunnel(options: nil)
            let before = await request(provider, ["method": "sessionSnapshot"])
            Harness.blockReload = true
            let reload = Task { await request(provider, ["method": "reloadCurrentSession", "sessionId": before["sessionId"] as? String ?? ""]) }
            let entered = await withCheckedContinuation { continuation in
                Thread.detachNewThread { continuation.resume(returning: Harness.reloadEntered.wait(timeout: .now() + 2) == .success) }
            }
            let snapshot = await request(provider, ["method": "tailnetSnapshot"])
            let passed = entered && snapshot["publicStatus"] as? String == "connecting" && snapshot["tailnetStatus"] as? String == "disabled"
            Harness.releaseReload.signal()
            _ = await reload.value
            await provider.stopTunnel(with: .userInitiated)
            print("\(passed ? "PASS" : "FAIL") ordinary-reloading: public status follows the in-flight core")
            Darwin.exit(passed ? 0 : 1)
        }
        _ = try store.setEnabled(0, true, requireStopped: { true })
        let prepared = try store.prepareStart(1)!
        let json = String(data: try JSONSerialization.data(withJSONObject: publicTailnetConfig(prepared)), encoding: .utf8)!
        try json.write(to: Harness.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try await provider.startTunnel(options: ["tailnetSettingsGeneration": NSNumber(value: 1), "tailnetNodeGeneration": prepared.nodeGeneration as NSString,
            "tailnetConfigSHA256": SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined() as NSString])
        var failures = [String]()
        func expect(_ value: Bool, _ text: String) { if !value { failures.append(text) } }
        let session = await request(provider, ["method": "sessionSnapshot"])
        let id = session["sessionId"] as? String ?? ""
        let old = Harness.platforms[0]
        let notice = LibboxNotification(); notice.openURL = "https://login.tailscale.com/a/PUBLIC_NATIVE_AUTH_FIXTURE"
        if scenario == "invalid-notification" { notice.identifier = "unknown" }
        old.tailnetNotification?(notice)
        let snapshot = await request(provider, ["method": "tailnetSnapshot"])
        expect(snapshot["schema"] as? Int == 1, "snapshot has exact native schema")
        expect(snapshot["authAvailable"] as? Bool == (scenario != "invalid-notification"), "only accepted current notification enables explicit login")
        let snapshotText = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
        expect(!snapshotText.contains("PUBLIC_NATIVE_AUTH_FIXTURE") && !snapshotText.contains("https://"), "snapshot never includes authentication URL")
        let requestID = UUID().uuidString
        let grant = await request(provider, ["method": "tailnetAuthentication", "sessionId": id, "nodeGeneration": prepared.nodeGeneration, "requestId": requestID])
        if scenario == "invalid-notification" {
            expect(grant["result"] as? String == "unavailable" && grant["url"] == nil, "invalid notification cannot transfer URL")
        } else {
            expect(grant["result"] as? String == "ready" && grant["url"] as? String == notice.openURL, "native-only provider reply transfers current URL once")
            let again = await request(provider, ["method": "tailnetAuthentication", "sessionId": id, "nodeGeneration": prepared.nodeGeneration, "requestId": UUID().uuidString])
            expect(again["result"] as? String == "unavailable", "URL cannot be transferred twice")
            if scenario == "stale-after-reload" {
                _ = await request(provider, ["method": "reloadCurrentSession", "sessionId": id])
                old.tailnetNotification?(notice)
                let after = await request(provider, ["method": "tailnetSnapshot"])
                expect(after["authAvailable"] as? Bool == false, "retired notification cannot authenticate replacement platform")
            }
            if scenario == "stale-after-stop" { await provider.stopTunnel(with: .userInitiated) }
            if scenario == "grant-expired" { try await Task.sleep(nanoseconds: 4_100_000_000) }
            let validate: [String: Any] = ["method": "tailnetAuthenticationValidate", "sessionId": id, "nodeGeneration": prepared.nodeGeneration,
                "requestId": requestID, "callbackId": grant["callbackId"] as? String ?? ""]
            let allowed = await request(provider, validate)
            let expected = !["stale-after-reload", "stale-after-stop", "grant-expired"].contains(scenario)
            expect(allowed["valid"] as? Bool == expected, "final native grant validation rechecks current owner and deadline")
            let replay = await request(provider, validate)
            expect(replay["valid"] as? Bool == false, "native validation grant is single use")
        }
        await provider.stopTunnel(with: .userInitiated)
        for failure in failures { print("FAIL \(scenario): \(failure)") }
        if failures.isEmpty { print("PASS \(scenario)") }
        Darwin.exit(failures.isEmpty ? 0 : 1)
    }
}
