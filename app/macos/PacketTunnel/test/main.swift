// Standalone test for TunnelProcessHealth — the policy that decides when a
// poisoned tunnel-extension process must be restarted.
//
// Run with app/macos/PacketTunnel/test/run.sh. No Xcode target needed: the
// type under test is deliberately free of NetworkExtension/Libbox imports so
// it can be compiled on its own.
//
// The rules being locked down here are not arithmetic, they are safety
// invariants. Restarting the process is the only way to reclaim a wedged
// sing-box instance, but an unconditional restart-on-failure turns a plain
// config error into an exit loop — the extension would die, NE would respawn
// it, and it would die again. Every case below exists to pin one side of that
// trade-off.

import Foundation

var failures = 0
var checks = 0

func expect(_ actual: Bool, _ expected: Bool, _ what: String) {
    checks += 1
    if actual != expected {
        failures += 1
        FileHandle.standardError.write(Data(
            "FAIL \(what): expected \(expected), got \(actual)\n".utf8
        ))
    }
}

// A process that has never run anything must never restart itself: the failure
// can only be a bad config or a dead network, and neither survives a respawn.
// This is the invariant that keeps the self-heal from becoming an exit loop —
// after a restart every flag is false again, so a repeating failure reports
// itself instead of cycling.
do {
    let h = TunnelProcessHealth()
    expect(h.isPoisoned, false, "fresh process is not poisoned")
    expect(h.shouldRestartAfterStartFailure(addressInUse: false), false,
           "fresh process does not restart on a plain start failure")
    expect(h.shouldRestartAfterStop(), false,
           "fresh process does not restart after a clean stop")
}

// A port held by a FOREIGN process cannot be freed by restarting ourselves, so
// address-in-use alone is not grounds for an exit. Only a port we ourselves
// bound earlier — and therefore leaked — is.
do {
    let h = TunnelProcessHealth()
    expect(h.shouldRestartAfterStartFailure(addressInUse: true), false,
           "address-in-use without ever having bound is a foreign holder")
}
do {
    let h = TunnelProcessHealth()
    h.markListenerBound()
    expect(h.shouldRestartAfterStartFailure(addressInUse: true), true,
           "address-in-use after we bound it once means we leaked it")
}

// The observed failure: a stop whose graceful shutdown exceeded its bound
// leaves a live sing-box instance holding working/cache.db. Nothing in-process
// can reclaim it, so the process must go before the next connect — otherwise
// every later start dies on "initialize cache-file: timeout".
do {
    let h = TunnelProcessHealth()
    h.markListenerBound()
    h.markServiceStarted()
    expect(h.isPoisoned, false, "a healthy session does not poison the process")
    h.markServiceLeaked("closeService exceeded its bound")
    expect(h.isPoisoned, true, "a wedged shutdown poisons the process")
    expect(h.shouldRestartAfterStop(), true,
           "a poisoned process restarts as soon as the stop is over")
}

// Backstop for the poisoning paths that never reach stopTunnel (a stopService
// that wedged, or a start that threw after the core came up): once a service
// has run in this process, a later start failure is far more likely to be
// leaked state than a new config error, so recover rather than stay broken.
do {
    let h = TunnelProcessHealth()
    h.markListenerBound()
    h.markServiceStarted()
    expect(h.shouldRestartAfterStartFailure(addressInUse: false), true,
           "a start failure after a prior service ran means leaked state")
}

// At most one restart per process, no matter how many paths ask for it. Two
// concurrent askers (a late stopTunnel and the next startTunnel) must not both
// schedule an exit.
do {
    let h = TunnelProcessHealth()
    h.markServiceLeaked("wedged")
    expect(h.shouldRestartAfterStop(), true, "first ask restarts")
    expect(h.shouldRestartAfterStop(), false, "second ask is a no-op")
    expect(h.shouldRestartAfterStartFailure(addressInUse: false), false,
           "a different path cannot re-arm the restart either")
}

// The reason is carried so the diagnostic log says WHY the process went away.
// Past failures on this extension were expensive precisely because the engine
// side left no evidence behind.
do {
    let h = TunnelProcessHealth()
    expect(h.poisonReason == nil, true, "no reason before any leak")
    h.markServiceLeaked("closeService exceeded its bound")
    expect(h.poisonReason == "closeService exceeded its bound", true,
           "leak reason is retained for the log")
    h.markServiceLeaked("something else later")
    expect(h.poisonReason == "closeService exceeded its bound", true,
           "the FIRST reason is kept — it is the one that explains the process")
}

if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    print("\(failures)/\(checks) checks FAILED")
    exit(1)
}
