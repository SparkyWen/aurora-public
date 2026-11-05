import Foundation

// libbox 1.13.14 starts independent status/group streams. Closing a connection
// reports disconnected once per stream; Connect closes an existing transport.
// Model those side effects, while keeping Aurora's implementation under test.
protocol LibboxCommandClientHandlerProtocol: AnyObject {
    func connected()
    func disconnected(_ message: String?)
    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?)
    func writeStatus(_ message: LibboxStatusMessage?)
}
let LibboxCommandStatus: Int32 = 1
let LibboxCommandGroup: Int32 = 2
class LibboxCommandClientOptions {
    var statusInterval: Int64 = 0
    func addCommand(_ command: Int32) {}
}
class LibboxCommandClient {
    static var all: [LibboxCommandClient] = []
    static var connectCalls = 0
    static var failuresRemaining = 0
    static var duringConnect: (() -> Void)?
    let handler: any LibboxCommandClientHandlerProtocol
    var active = false
    var selections: [String] = []
    var urlTests: [String] = []
    init(_ handler: any LibboxCommandClientHandlerProtocol) { self.handler = handler }
    func connect() throws {
        Self.connectCalls += 1
        if active { breakTransport() }
        if Self.failuresRemaining > 0 {
            Self.failuresRemaining -= 1
            throw AuroraVPNError("unavailable")
        }
        Self.duringConnect?()
        active = true
        handler.connected()
    }
    func disconnect() throws { if active { breakTransport() } }
    func breakTransport() {
        active = false
        handler.disconnected("status stream unavailable")
        handler.disconnected("group stream unavailable")
    }
    func selectOutbound(_ group: String, outboundTag: String) throws {
        selections.append("\(group):\(outboundTag)")
    }
    func urlTest(_ group: String) throws { urlTests.append(group) }
}
func LibboxNewCommandClient(_ handler: any LibboxCommandClientHandlerProtocol, _ options: LibboxCommandClientOptions) -> LibboxCommandClient? {
    let client = LibboxCommandClient(handler)
    LibboxCommandClient.all.append(client)
    return client
}
// Pure deterministic scheduling: every turn executes only already-queued work.
class DispatchQueue {
    static let shared = DispatchQueue()
    static var work: [() -> Void] = []
    static func global() -> DispatchQueue { shared }
    func async(execute body: @escaping () -> Void) { Self.work.append(body) }
    func asyncAfter(deadline: DispatchTime, execute body: @escaping () -> Void) { Self.work.append(body) }
    static func advance() {
        let pending = work
        work.removeAll()
        for body in pending { body() }
    }
    static func drain(_ turns: Int = 8) { for _ in 0..<turns { advance() } }
}
struct AuroraVPNError: Error { init(_ message: String) {} }
enum AuroraVPN { static func diag(_ message: String) {} }
class LibboxStatusMessage {
    var uplink: Int64 = 0, downlink: Int64 = 0, uplinkTotal: Int64 = 0, downlinkTotal: Int64 = 0
}
protocol LibboxOutboundGroupIteratorProtocol { func hasNext() -> Bool; func next() -> LibboxOutboundGroup? }
class LibboxOutboundGroup {
    var tag = "", type = "", selected = ""
    var selectable = false
    func getItems() -> (any LibboxOutboundGroupItemIteratorProtocol)? { nil }
}
protocol LibboxOutboundGroupItemIteratorProtocol { func hasNext() -> Bool; func next() -> LibboxOutboundGroupItem? }
class LibboxOutboundGroupItem { var tag = "", type = ""; var urlTestDelay: Int32 = 0 }
protocol LibboxStringIteratorProtocol {}
protocol LibboxLogIteratorProtocol {}
class LibboxConnectionEvents {}
