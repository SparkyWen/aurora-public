import Foundation

/// Process-scoped health of the tunnel extension, and the policy for giving up
/// on a process that can no longer host a tunnel.
///
/// macOS keeps the PacketTunnel **system extension process alive across every
/// tunnel session**, so anything a session leaks is inherited by all the
/// sessions after it. sing-box's shutdown can wedge: a stuck outbound blocks
/// `CloseService()` indefinitely ("close outbound/shadowsocks[...] take too
/// much time to finish!"), and the bounded stop gives up on it. The instance is
/// then still running inside this process, still holding every exclusive
/// resource it acquired. Nothing in-process can reclaim them:
///
///   - first failure — the leaked resource was the command server's
///     fixed listener on 127.0.0.1:42813, and every later start died on
///     EADDRINUSE.
///   - second failure — with the listener force-freed, the *next*
///     exclusive resource took over: the bbolt lock on `working/cache.db`.
///     Every later start died on `initialize cache-file: timeout`, forever,
///     until the extension was killed by hand. Observed: the live
///     sysext held fd 11 on that file while the tunnel sat in "Connecting".
///
/// Chasing these one resource at a time does not converge — the leak is of the
/// whole sing-box instance, so the fix has to be at that granularity too. The
/// process is the only reclaim boundary macOS gives us, and NE relaunches the
/// extension on the next connect, so a poisoned process should exit rather than
/// stay up and fail identically forever.
///
/// The counterweight is that an unconditional restart-on-failure turns a plain
/// config error into an exit loop. Hence the flags below: a restart is only
/// justified when this process is known to have had something to leak. A fresh
/// process never restarts itself, which is what bounds the recovery to a single
/// exit — after it, every flag is false again.
///
/// Pure by construction (Foundation only) so `test/run.sh` can compile and
/// exercise these rules without an Xcode target.
final class TunnelProcessHealth: @unchecked Sendable {
    /// The one instance that matters at runtime. Tests build their own.
    static let shared = TunnelProcessHealth()

    private let lock = NSLock()
    private var serviceLeaked = false
    private var everStartedService = false
    private var everBoundListener = false
    private var restartRequested = false
    private var leakReason: String?

    /// The command server's listener is bound. Recorded because a *later*
    /// EADDRINUSE then means we leaked the port ourselves, as opposed to some
    /// foreign process holding it — which restarting could never fix.
    func markListenerBound() {
        lock.lock()
        defer { lock.unlock() }
        everBoundListener = true
    }

    /// A sing-box service actually came up in this process. From here on the
    /// process has something worth leaking, and a start failure is more likely
    /// to be inherited wreckage than a fresh configuration problem.
    func markServiceStarted() {
        lock.lock()
        defer { lock.unlock() }
        everStartedService = true
    }

    /// A shutdown exceeded its bound: a live sing-box instance we can no longer
    /// reach is still holding its resources. Only the first reason is kept —
    /// it is the one that explains why the process has to go.
    func markServiceLeaked(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        serviceLeaked = true
        if leakReason == nil { leakReason = reason }
    }

    var isPoisoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return serviceLeaked
    }

    /// A requested exit is delayed long enough to deliver its error. That
    /// interval must not admit a new session that the pending exit would kill.
    var isRestartPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return restartRequested
    }

    /// Why the process is unusable, for the diagnostic log. Past failures on
    /// this extension cost days precisely because the engine side left no
    /// evidence of what it had done.
    var poisonReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return leakReason
    }

    /// After a stop: restart only if that stop actually leaked an instance.
    /// Doing it here — rather than waiting for the next start to fail — is what
    /// makes the recovery invisible, because the poisoned process is gone
    /// before the user asks to connect again.
    func shouldRestartAfterStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimRestartLocked(serviceLeaked)
    }

    /// After a failed start: the backstop for poisoning that never reached
    /// `stopTunnel` — a `stopService` that wedged, or a start that threw once
    /// the core was already up.
    ///
    /// `addressInUse` is passed in rather than matched here because libbox
    /// surfaces the bind failure only as a wrapped Go error string; the caller
    /// owns that string matching, and it is used solely to pick a recovery
    /// path, never to decide correctness.
    func shouldRestartAfterStartFailure(addressInUse: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let leakedSomething = serviceLeaked
            || everStartedService
            || (addressInUse && everBoundListener)
        return claimRestartLocked(leakedSomething)
    }

    /// At most one restart per process, whoever asks first. Two paths can race
    /// here — a late `stopTunnel` and the next `startTunnel` — and both
    /// scheduling an exit would be a double teardown for no extra recovery.
    private func claimRestartLocked(_ justified: Bool) -> Bool {
        guard justified, !restartRequested else { return false }
        restartRequested = true
        return true
    }
}
