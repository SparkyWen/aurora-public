import Foundation
import Darwin

enum AuroraTailnetAuthFailure: String, Error { case invalidArguments = "invalid-arguments" }
final class AuroraTailnetAuth {
    final class Owner {
        let sessionID: String
        let nodeGeneration: String
        fileprivate init(_ sessionID: String, _ nodeGeneration: String) {
            self.sessionID = sessionID; self.nodeGeneration = nodeGeneration
        }
    }
    final class OpenRequest {
        fileprivate let owner: Owner
        fileprivate init(_ owner: Owner) { self.owner = owner }
    }
    enum OpenResult: String { case opened, unavailable, stale }
    private struct Pending { let url: String; let receivedAt: Int64 }
    private let lock = NSLock()
    private let clock: () throws -> Int64
    private var current: Owner?
    private var pending: Pending?
    private var queued: OpenRequest?

    init(elapsedRealtimeMillis: @escaping () throws -> Int64 = AuroraTailnetAuth.elapsedRealtimeMillis) {
        clock = elapsedRealtimeMillis
    }
    // CLOCK_MONOTONIC_RAW includes system sleep; wall time and mach_absolute_time
    // cannot enforce this local five-minute lifetime across a device lock/sleep.
    static func elapsedRealtimeMillis() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
    }
    func beginOwner(sessionID: String, nodeGeneration: String) throws -> Owner {
        try locked {
            guard validUUID(sessionID), validUUID(nodeGeneration) else { throw AuroraTailnetAuthFailure.invalidArguments }
            clear()
            let owner = Owner(sessionID, nodeGeneration)
            current = owner
            return owner
        }
    }
    func receive(_ owner: Owner, identifier: String, typeID: Int, rawURL: String) -> Bool {
        locked {
            guard current === owner, identifier == "tailscale-authentication", typeID == 10,
                  validURL(rawURL), let now = now() else { return false }
            pending = Pending(url: rawURL, receivedAt: now)
            queued = nil
            return true
        }
    }
    func authenticationRequired(_ owner: Owner) -> Bool { locked { live(owner) != nil } }
    func requestOpen(_ owner: Owner, userGesture: Bool) -> OpenRequest? {
        locked {
            guard userGesture, live(owner) != nil, queued == nil else { return nil }
            let ticket = OpenRequest(owner)
            queued = ticket
            return ticket
        }
    }
    // Invoke on the final native UI dispatch. The sink only makes the synchronous,
    // nonblocking browser launch call; it must not queue it or reenter this holder.
    // This short lock orders invalidation with that call; the URL never leaves
    // native memory or appears in the ticket, errors, diagnostics, or Dart.
    func dispatchOpen(_ request: OpenRequest, launch: (String) throws -> Void) -> OpenResult {
        locked {
            guard current === request.owner else { return .stale }
            guard queued === request, let value = live(request.owner) else { return .unavailable }
            clear()
            do { try launch(value.url); return .opened }
            catch { return .unavailable }
        }
    }
    func invalidate(_ owner: Owner) {
        locked { if current === owner { clear(); current = nil } }
    }
    private func clear() { pending = nil; queued = nil }
    private func now() -> Int64? {
        guard let value = try? clock(), value >= 0 else { return nil }
        return value
    }
    private func live(_ owner: Owner) -> Pending? {
        guard current === owner, let value = pending else { return nil }
        guard let now = now(), now >= value.receivedAt, now - value.receivedAt < 300_000 else {
            clear(); return nil
        }
        return value
    }
    private func validUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }
    private func validURL(_ value: String) -> Bool {
        guard value.utf8.count <= 4096, value.hasPrefix("https://"),
              !value.unicodeScalars.contains(where: {
                  $0.value <= 32 || (127...159).contains($0.value) || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return false }
        let authority = value.dropFirst(8).prefix { !"/?#".contains($0) }
        guard authority == "login.tailscale.com" || authority == "login.tailscale.com:443" else { return false }
        // Foundation can repair invalid characters while parsing. Reject those
        // spellings instead of silently opening a different normalized URL.
        let path = value.dropFirst(8 + authority.count).prefix { !"?#".contains($0) }
        guard !path.contains("["), !path.contains("]") else { return false }
        let bytes = Array(value.utf8)
        let forbidden = Set("<>\"{}|\\^`".utf8)
        func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        for (index, byte) in bytes.enumerated() {
            if forbidden.contains(byte) { return false }
            if byte == 37 && (index + 2 >= bytes.count || !hex(bytes[index + 1]) || !hex(bytes[index + 2])) { return false }
        }
        guard let url = URLComponents(string: value), url.scheme == "https", url.host == "login.tailscale.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443, url.url != nil else { return false }
        return true
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}
