var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); failures += 1 }
}
func resetTest() {
    DispatchQueue.work.removeAll()
    LibboxCommandClient.all.removeAll()
    LibboxCommandClient.connectCalls = 0
    LibboxCommandClient.failuresRemaining = 0
    LibboxCommandClient.duringConnect = nil
}

// Regression: two stream errors for a single transport must produce one dial.
resetTest()
do {
    let client = AuroraCommandClient(onStatus: { _ in }, onGroups: { _ in })
    client.start()
    DispatchQueue.drain()
    let old = LibboxCommandClient.all.last!
    old.breakTransport()
    DispatchQueue.drain()
    expect(LibboxCommandClient.connectCalls == 2, "one interrupted transport must cause one reconnect; got \(LibboxCommandClient.connectCalls) total dials")
    // A callback may already be queued on a retired transport after replacement.
    old.handler.disconnected("late old stream error")
    DispatchQueue.drain()
    expect(LibboxCommandClient.connectCalls == 2, "late old stream must not restart its replacement")
    client.stop()
    DispatchQueue.drain()
}

// Queued retries cannot resurrect a client after the VPN stops.
resetTest()
do {
    let client = AuroraCommandClient(onStatus: { _ in }, onGroups: { _ in })
    client.start()
    DispatchQueue.drain()
    let old = LibboxCommandClient.all.last!
    old.breakTransport()
    client.stop()
    DispatchQueue.drain()
    old.handler.connected()
    old.handler.disconnected("late after stop")
    DispatchQueue.drain()
    expect(LibboxCommandClient.connectCalls == 1, "stop invalidates every queued retry and late callback")
}

// A failed dial must still retry, and selections must reach the new transport.
resetTest()
do {
    LibboxCommandClient.failuresRemaining = 1
    let client = AuroraCommandClient(onStatus: { _ in }, onGroups: { _ in })
    client.start()
    try client.select("proxy", "via-relay")
    DispatchQueue.drain()
    expect(LibboxCommandClient.connectCalls == 2, "failed dial must retry exactly once after recovery")
    expect(LibboxCommandClient.all.last!.selections == ["proxy:via-relay"], "latest requested selection is replayed on connection")
    client.stop()
}
// Requests made before the asynchronous connection must not be lost.
resetTest()
do {
    let client = AuroraCommandClient(onStatus: { _ in }, onGroups: { _ in })
    client.start()
    client.start()
    client.urlTest("via-relay")
    DispatchQueue.drain()
    expect(LibboxCommandClient.connectCalls == 1, "repeated start does not duplicate the live connection")
    expect(LibboxCommandClient.all.last!.urlTests == ["via-relay"], "startup URL test reaches the connected transport")
    client.stop()
}

// A disconnect can arrive between connected() and its queued command replay.
resetTest()
do {
    let client = AuroraCommandClient(onStatus: { _ in }, onGroups: { _ in })
    client.start()
    client.urlTest("via-relay")
    DispatchQueue.advance()
    LibboxCommandClient.all.last!.breakTransport()
    DispatchQueue.drain()
    expect(LibboxCommandClient.all.last!.urlTests == ["via-relay"], "replacement preserves a URL test whose old replay was cancelled")
    client.stop()
}

// Stop can occur while libbox's synchronous connect() is still dialing.
resetTest()
do {
    let client = AuroraCommandClient(onStatus: { _ in }, onGroups: { _ in })
    LibboxCommandClient.duringConnect = { client.stop() }
    client.start()
    DispatchQueue.drain()
    expect(!LibboxCommandClient.all.last!.active, "a dial that completes after stop must be closed")
    expect(LibboxCommandClient.connectCalls == 1, "late dial completion cannot schedule reconnects")
}

// Retired streams cannot publish stale traffic after the replacement is up.
resetTest()
do {
    var statusCount = 0
    let client = AuroraCommandClient(onStatus: { _ in statusCount += 1 }, onGroups: { _ in })
    client.start()
    DispatchQueue.drain()
    let old = LibboxCommandClient.all.last!
    old.breakTransport()
    DispatchQueue.drain()
    old.handler.writeStatus(LibboxStatusMessage())
    expect(statusCount == 0, "retired stream status must be ignored")
    LibboxCommandClient.all.last!.handler.writeStatus(LibboxStatusMessage())
    expect(statusCount == 1, "current stream status must still be delivered")
    client.stop()
}
if failures > 0 { exit(1) }
print("PASS: command-client reconnect, stale callback, stop, and selection regressions")
