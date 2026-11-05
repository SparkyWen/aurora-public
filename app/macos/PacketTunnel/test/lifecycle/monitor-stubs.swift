import Foundation
import Darwin

// Deterministic substitutes for asynchronous system boundaries. The production
// monitor implementation is extracted verbatim; no lifecycle algorithm is copied.
final class PacketTunnelProvider {}
final class NEPacketTunnelNetworkSettings {}
// Only the iOS platform stores a Tailnet notification sink; the extracted
// monitor body never invokes it, so the type only has to exist.
final class LibboxNotification {}
struct AuroraError: Error { let message: String; init(_ message: String) { self.message = message } }
func extDiag(_ message: String) {}
protocol LibboxInterfaceUpdateListenerProtocol: AnyObject {
    func updateDefaultInterface(_ name: String, interfaceIndex: Int32, isExpensive: Bool, isConstrained: Bool)
}
class Listener: LibboxInterfaceUpdateListenerProtocol {
    var updates: [String] = []
    func updateDefaultInterface(_ name: String, interfaceIndex: Int32, isExpensive: Bool, isConstrained: Bool) { updates.append(name) }
}
final class Harness {
    static var jobs: [() -> Void] = []
    static var timers: [DispatchSourceTimer] = []
    static var monitors: [NWPathMonitor] = []
    static var beforeFirstPath: (() -> Void)?
    static var unsignaledWaits = 0
    static func next() -> Bool {
        guard !jobs.isEmpty else { return false }
        jobs.removeFirst()()
        return true
    }
    static func drain() { var budget = 100; while budget > 0 && next() { budget -= 1 }; precondition(budget > 0) }
}
final class DispatchQueue {
    init(label: String) {}
    func async(execute body: @escaping () -> Void) { Harness.jobs.append(body) }
}
final class DispatchSemaphore {
    var count: Int
    init(value: Int) { count = value }
    func signal() { count += 1 }
    func wait() {
        var budget = 100
        while count == 0 && budget > 0 && Harness.next() { budget -= 1 }
        precondition(budget > 0)
        if count == 0 { Harness.unsignaledWaits += 1 } else { count -= 1 }
    }
}
struct DispatchTime {
    static func now() -> DispatchTime { DispatchTime() }
    static func + (_ lhs: DispatchTime, _ rhs: Int) -> DispatchTime { lhs }
}
final class DispatchSourceTimer {
    var cancelled = false
    var handler: (() -> Void)?
    func schedule(deadline: DispatchTime, repeating: Int) {}
    func setEventHandler(handler: @escaping () -> Void) { self.handler = handler }
    func resume() {}
    func cancel() { cancelled = true }
}
enum DispatchSource {
    static func makeTimerSource(queue: DispatchQueue) -> DispatchSourceTimer {
        let timer = DispatchSourceTimer(); Harness.timers.append(timer); return timer
    }
}
final class NWInterface {
    enum InterfaceType { case wifi, cellular, wiredEthernet, loopback, other }
    let name: String
    let index: Int
    let type: InterfaceType
    init(_ name: String, _ index: Int, _ type: InterfaceType) { self.name = name; self.index = index; self.type = type }
}
enum Network {
    struct NWPath {
        enum Status { case satisfied, unsatisfied, requiresConnection }
        var status: Status = .satisfied
        var availableInterfaces: [NWInterface] = [NWInterface("en0", 4, .wifi)]
        var isExpensive = false
        var isConstrained = false
    }
}
final class NWPathMonitor {
    var currentPath = Network.NWPath()
    var pathUpdateHandler: ((Network.NWPath) -> Void)?
    var cancelled = false
    init() { Harness.monitors.append(self) }
    func start(queue: DispatchQueue) {
        let hook = Harness.beforeFirstPath; Harness.beforeFirstPath = nil; hook?()
        queue.async { if !self.cancelled { self.pathUpdateHandler?(self.currentPath) } }
    }
    func cancel() { cancelled = true }
}

final class GoSeqRef {
    let refnum: Int32
    init(_ refnum: Int32) { self.refnum = refnum }
}
final class LibboxInterfaceUpdateListener: Listener {
    let _ref: Any
    init(_ refnum: Int32) { _ref = GoSeqRef(refnum) }
}
