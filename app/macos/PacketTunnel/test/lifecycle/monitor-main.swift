import Darwin

let platform = AuroraPlatform(provider: PacketTunnelProvider())
let scenario = CommandLine.arguments[1]
let first: Listener = scenario.hasPrefix("proxy-") ? LibboxInterfaceUpdateListener(-42) : Listener()
let second: Listener = scenario.hasPrefix("proxy-") ? LibboxInterfaceUpdateListener(-43) : Listener()
var failures: [String] = []
func expect(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
if scenario == "close-before-first-path" {
    Harness.beforeFirstPath = { try! platform.closeDefaultInterfaceMonitor(first) }
    var threw = false
    do { try platform.startDefaultInterfaceMonitor(first) } catch { threw = true }
    Harness.drain()
    expect(threw, "cancelled monitor startup must report failure")
    expect(Harness.unsignaledWaits == 0, "cancelled startup must release its initial-path wait")
    expect(Harness.monitors.allSatisfy { $0.cancelled }, "cancelled startup must leave no monitor")
    expect(Harness.timers.allSatisfy { $0.cancelled }, "cancelled startup must leave no reconcile timer")
} else {
    try platform.startDefaultInterfaceMonitor(first)
    let old = Harness.monitors[0]
    let oldCallback = old.pathUpdateHandler!
    let oldCount = first.updates.count
    if scenario == "reset-before-replacement" { platform.reset() }
    if scenario != "normal-close" && scenario != "proxy-rewrapped-close" {
        try platform.startDefaultInterfaceMonitor(second)
        let replacement = Harness.monitors.last!
        if scenario == "late-close" { try platform.closeDefaultInterfaceMonitor(first) }
        if scenario == "proxy-late-close" { try platform.closeDefaultInterfaceMonitor(LibboxInterfaceUpdateListener(-42)) }
        if scenario == "late-callback" {
            Harness.jobs.append { oldCallback(Network.NWPath(availableInterfaces: [NWInterface("en9", 9, .wiredEthernet)])) }
        }
        Harness.drain()
        expect(!replacement.cancelled, "retired work must not cancel the replacement monitor")
        expect(old.cancelled, "replacement must retire the old monitor")
        expect(first.updates.count == oldCount, "retired callbacks must not publish interface updates")
        expect(second.updates == ["en0"], "replacement must deliver its initial path once")
        expect(Harness.unsignaledWaits == 0, "replacement startup must obtain its initial path")
        try platform.closeDefaultInterfaceMonitor(second)
    } else {
        try platform.closeDefaultInterfaceMonitor(scenario == "proxy-rewrapped-close" ? LibboxInterfaceUpdateListener(-42) : first)
    }
    Harness.drain()
    expect(Harness.monitors.allSatisfy { $0.cancelled }, "final close must retire its own monitor")
    expect(Harness.timers.allSatisfy { $0.cancelled }, "final close must retire its own timer")
}
for message in failures { print("FAIL \(scenario): \(message)") }
if failures.isEmpty { print("PASS \(scenario)") }
Darwin.exit(failures.isEmpty ? 0 : 1)
