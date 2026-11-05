import Foundation

final class WeakRunner {
    weak var value: AuroraVPN?
    init(_ value: AuroraVPN) { self.value = value }
}

@main struct MobileRunnerTests {
    static var failures = 0
    static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !value() { failures += 1; print("FAIL: \(label)") }
    }
    @MainActor static func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }
    @MainActor static func invoke(_ method: String, _ args: Any? = nil) async -> Any? {
        await withCheckedContinuation { continuation in
            FlutterMethodChannel.current.handler?(FlutterMethodCall(method, args)) { continuation.resume(returning: $0) }
        }
    }
    @MainActor static func make(_ foreignFirst: Bool = false) async -> (AuroraVPN, NETunnelProviderSession) {
        NETunnelProviderManager.saves = 0; NEVPNConnection.starts = 0; NEVPNConnection.stops = 0
        NETunnelProviderManager.saveAction = nil; NETunnelProviderManager.loadAction = nil
        AuroraCommandClient.all = []
        let own = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol(); proto.providerBundleIdentifier = AuroraVPN.providerBundleID
        own.protocolConfiguration = proto
        let session = own.connection as! NETunnelProviderSession; session.status = .connected
        NETunnelProviderManager.managers = [own]
        if foreignFirst {
            let foreign = NETunnelProviderManager(); let other = NETunnelProviderProtocol()
            other.providerBundleIdentifier = "other.provider"; foreign.protocolConfiguration = other
            foreign.connection.status = .connected; NETunnelProviderManager.managers.insert(foreign, at: 0)
        }
        let vpn = AuroraVPN(messenger: TestMessenger())
        _ = FlutterEventChannel.channels["aurora/events"]!.handler!.onListen(withArguments: nil, eventSink: { _ in })
        await settle()
        return (vpn, session)
    }
    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    @MainActor static func changed(_ session: NEVPNConnection, _ status: NEVPNStatus) {
        session.status = status
        NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: session)
    }
    @MainActor static func completedOwner() async -> WeakRunner {
        let (vpn, _) = await make()
        _ = await invoke("sessionSnapshot")
        return WeakRunner(vpn)
    }
    @MainActor static func main() async {
        let scenario = CommandLine.arguments.dropFirst().first ?? "all"
        if scenario == "all" || scenario == "snapshot" {
            let (vpn, session) = await make(true)
            let snapshot = await invoke("sessionSnapshot") as? [String: Any]
            expect(snapshot?["sessionId"] as? String == session.sessionID, "snapshot selects only own existing provider")
            expect(snapshot?["status"] as? String == "connected", "snapshot reports native session status")
            expect(NEVPNConnection.starts == 0 && NEVPNConnection.stops == 0 && NETunnelProviderManager.saves == 0, "snapshot never starts/stops/saves/enables a VPN")
            _ = vpn
        }
        if scenario == "all" || scenario == "reload" {
            let (vpn, session) = await make()
            let oldClient = AuroraCommandClient.all.last
            var retiredBeforeReload = false
            session.onMessage = { message, reply in
                if message["method"] as? String == "reloadCurrentSession" {
                    retiredBeforeReload = oldClient?.stops == 1
                    reply(try! JSONSerialization.data(withJSONObject: ["result": "reloaded"]))
                } else { reply(try! JSONSerialization.data(withJSONObject: ["status": "connected", "sessionId": session.sessionID])) }
            }
            let answer = await invoke("reloadCurrentSession", ["sessionId": session.sessionID]) as? String
            expect(answer == "reloaded", "same-session reload returns typed success")
            expect(retiredBeforeReload, "telemetry retires before native core reload")
            expect(AuroraCommandClient.all.count == 2, "same UUID is rechecked before telemetry resumes")
            expect(NEVPNConnection.starts == 0 && NEVPNConnection.stops == 0 && NETunnelProviderManager.saves == 0, "reload never creates or stops a system VPN")
            _ = vpn
        }
        if scenario == "all" || scenario == "mismatch" {
            let (vpn, session) = await make()
            let answer = await invoke("reloadCurrentSession", ["sessionId": UUID().uuidString]) as? String
            expect(answer == "unavailable", "stale UUID is unavailable")
            expect(!session.calls.contains("reloadCurrentSession"), "stale UUID never reaches native reload")
            _ = vpn
        }
        if scenario == "all" || scenario == "isolation" {
            let (vpn, session) = await make(true)
            let oldClient = AuroraCommandClient.all.last!
            changed(NETunnelProviderManager.managers[0].connection, .disconnected)
            await settle()
            expect(oldClient.stops == 0, "foreign VPN status cannot retire own telemetry")
            expect(NETunnelProviderManager.managers.allSatisfy { !$0.isEnabled }, "read-only adoption does not enable any manager")
            changed(session, .disconnected)
            await settle()
            let snapshot = await invoke("sessionSnapshot") as? [String: Any]
            let answer = await invoke("reloadCurrentSession", ["sessionId": session.sessionID]) as? String
            expect(snapshot?["sessionId"] is NSNull && answer == "unavailable", "disconnected session has no recoverable UUID")
            expect(session.calls.isEmpty, "disconnected session sends no provider message")
            _ = vpn
        }
        if scenario == "all" || scenario == "single-flight" {
            let (vpn, session) = await make()
            var pending: ((Data?) -> Void)?
            session.onMessage = { message, reply in
                if message["method"] as? String == "reloadCurrentSession" { pending = reply }
                else { reply(json(["status": "connected", "sessionId": session.sessionID])) }
            }
            let first = Task { @MainActor in await invoke("reloadCurrentSession", ["sessionId": session.sessionID]) as? String }
            await settle()
            let second = await invoke("reloadCurrentSession", ["sessionId": session.sessionID]) as? String
            changed(session, .connected)
            expect(second == "unavailable" && session.calls.filter { $0 == "reloadCurrentSession" }.count == 1, "single-flight sends one native reload")
            expect(AuroraCommandClient.all.count == 1, "connected notification during reload cannot recreate telemetry")
            pending?(json(["result": "reloaded"]))
            let firstAnswer = await first.value
            expect(firstAnswer == "reloaded", "first single-flight request completes")
            _ = vpn
        }
        if scenario == "all" || scenario == "callbacks" {
            let (vpn, session) = await make()
            let oldClient = AuroraCommandClient.all.last!
            var stats: [[String: Any]] = [], groups: [[[String: Any]]] = []
            _ = FlutterEventChannel.channels["aurora/stats"]!.handler!.onListen(withArguments: nil, eventSink: { stats.append($0 as! [String: Any]) })
            _ = FlutterEventChannel.channels["aurora/groups"]!.handler!.onListen(withArguments: nil, eventSink: { groups.append($0 as! [[String: Any]]) })
            oldClient.onStop = { oldClient.onStatus(["stale": true]); oldClient.onGroups([["stale": true]]) }
            _ = await invoke("reloadCurrentSession", ["sessionId": session.sessionID])
            oldClient.onStatus(["stale": true]); oldClient.onGroups([["stale": true]])
            let newClient = AuroraCommandClient.all.last!
            newClient.onStatus(["fresh": true]); newClient.onGroups([["fresh": true]])
            await settle()
            expect(!stats.contains { $0["stale"] != nil } && !groups.contains { $0.first?["stale"] != nil }, "queued old generation stats/groups are discarded after reload")
            expect(stats.last?["fresh"] as? Bool == true && groups.last?.first?["fresh"] as? Bool == true, "fresh telemetry generation is delivered")
            _ = vpn
        }
        if scenario == "all" || scenario == "replacement" {
            let (vpn, session) = await make()
            let expected = session.sessionID
            session.onMessage = { message, reply in
                if message["method"] as? String == "reloadCurrentSession" {
                    session.sessionID = UUID().uuidString
                    reply(json(["result": "reloaded"]))
                } else { reply(json(["status": "connected", "sessionId": session.sessionID])) }
            }
            let answer = await invoke("reloadCurrentSession", ["sessionId": expected]) as? String
            expect(answer == "requiresReconnect", "post-reload UUID replacement cannot report success")
            changed(session, .connected)
            expect(AuroraCommandClient.all.count == 1, "old reply and connected status cannot resume telemetry for another UUID")
            expect(NEVPNConnection.starts == 0 && NEVPNConnection.stops == 0, "UUID mismatch never starts or stops replacement VPN")
            _ = vpn
        }
        if scenario == "all" || scenario == "native-failure" {
            let (vpn, session) = await make()
            session.onMessage = { message, reply in
                if message["method"] as? String == "reloadCurrentSession" {
                    changed(session, .disconnected)
                    reply(json(["result": "requiresReconnect"]))
                } else { reply(json(["status": "connected", "sessionId": session.sessionID])) }
            }
            let answer = await invoke("reloadCurrentSession", ["sessionId": session.sessionID]) as? String
            expect(answer == "requiresReconnect", "native disconnect before reply retains manual reconnect result")
            expect(AuroraCommandClient.all.count == 1 && NEVPNConnection.stops == 0, "native failure never resumes telemetry or issues another VPN stop")
            _ = vpn
        }
        if scenario == "all" || scenario == "manual-cancel" {
            let (vpn, session) = await make()
            var pending: ((Data?) -> Void)?, replies = 0
            session.onMessage = { message, reply in
                if message["method"] as? String == "reloadCurrentSession" { pending = reply }
                else { reply(json(["status": "connected", "sessionId": session.sessionID])) }
            }
            let channel = FlutterMethodChannel.current!
            var oldAnswer: String?
            channel.handler?(FlutterMethodCall("reloadCurrentSession", ["sessionId": session.sessionID])) { replies += 1; oldAnswer = $0 as? String }
            await settle()
            _ = await invoke("prepare")
            session.sessionID = UUID().uuidString
            changed(session, .connected)
            await settle()
            let count = AuroraCommandClient.all.count
            pending?(json(["result": "reloaded"]))
            pending?(json(["result": "requiresReconnect"]))
            await settle()
            expect(replies == 1 && oldAnswer == "unavailable", "manual intent cancels old RPC exactly once despite repeated late replies")
            expect(AuroraCommandClient.all.count == count && count == 2, "late old reply cannot change new manual session telemetry")
            _ = vpn
        }
        if scenario == "all" || scenario == "queued-stop" {
            let (vpn, _) = await make()
            var stopped = false, prepared = false
            let channel = FlutterMethodChannel.current!
            channel.handler?(FlutterMethodCall("stop", nil)) { _ in stopped = true }
            channel.handler?(FlutterMethodCall("prepare", nil)) { _ in prepared = true }
            await settle()
            expect(stopped && prepared && NEVPNConnection.stops == 0, "queued old stop cannot stop a newer manual intent")
            _ = vpn
        }
        if scenario == "all" || scenario == "stale-save" {
            let (vpn, _) = await make()
            var loaded: CheckedContinuation<Void, Never>?
            NETunnelProviderManager.saveAction = { throw NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationStale.rawValue) }
            NETunnelProviderManager.loadAction = { await withCheckedContinuation { loaded = $0 } }
            let prepare = Task { @MainActor in await invoke("prepare") }
            await settle()
            expect(loaded != nil, "stale preference recovery is waiting at real async load")
            _ = await invoke("stop")
            loaded?.resume()
            let result = await prepare.value as? FlutterError
            expect(result?.code == "prepare_failed" && NETunnelProviderManager.saves == 1, "cancelled stale preference retry never saves again")
            _ = vpn
        }
        if scenario == "all" || scenario == "completed-reply-release" {
            let released = await completedOwner()
            await settle()
            expect(released.value == nil, "completed RPC deadline releases its Runner owner")
        }
        if scenario == "all" || scenario == "short-deadlines" {
            let (vpn, session) = await make()
            session.onMessage = { _, _ in }
            let began = ProcessInfo.processInfo.systemUptime
            let snapshot = await invoke("sessionSnapshot") as? [String: Any]
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            expect(snapshot?["sessionId"] is NSNull && elapsed >= 2.8 && elapsed < 4, "unanswered native snapshot expires at its real three-second bound")
            session.onMessage = nil
            let releaseStop = DispatchSemaphore(value: 0)
            AuroraCommandClient.all.last!.onStop = { releaseStop.wait() }
            let reload = Task { @MainActor in await invoke("reloadCurrentSession", ["sessionId": session.sessionID]) as? String }
            await settle()
            expect(!session.calls.contains("reloadCurrentSession"), "main actor remains responsive while telemetry shutdown waits off-main")
            let answer = await reload.value
            releaseStop.signal()
            expect(answer == "requiresReconnect" && !session.calls.contains("reloadCurrentSession"), "unconfirmed telemetry retirement prevents native core reload")
            changed(session, .connected)
            expect(AuroraCommandClient.all.count == 1, "failed retirement cannot prematurely restore telemetry")
            _ = vpn
        }
        if scenario == "all" || scenario == "timeout" {
            let (vpn, session) = await make()
            var nativeStarted = false, late: ((Data?) -> Void)?
            session.onMessage = { message, reply in
                if message["method"] as? String == "reloadCurrentSession" { nativeStarted = true; late = reply }
                else { reply(json(["status": nativeStarted ? "connecting" : "connected", "sessionId": session.sessionID])) }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let answer = await invoke("reloadCurrentSession", ["sessionId": session.sessionID]) as? String
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            expect(answer == "requiresReconnect" && elapsed >= 21 && elapsed < 26, "real RPC deadline returns requiresReconnect while provider remains busy")
            late?(json(["result": "reloaded"]))
            changed(session, .connected)
            await settle()
            expect(AuroraCommandClient.all.count == 1 && NEVPNConnection.starts == 0, "timeout and late reply cannot recreate telemetry or VPN")
            _ = vpn
        }
        if failures > 0 { exit(1) }
        print("PASS: \(checks) real iOS Runner mobile session boundary checks")
    }
}
