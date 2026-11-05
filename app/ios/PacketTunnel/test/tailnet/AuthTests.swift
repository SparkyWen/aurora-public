import Foundation
import Darwin

private let session = "12345678-1234-1234-1234-123456789ABC"
private let node = "ABCDEF12-1234-1234-1234-ABCDEF123456"
private let authURL = "https://login.tailscale.com/a/public-fixture"
private let identifier = "tailscale-authentication"
private enum Failure: Error { case assertion, injected }
private func check(_ value: @autoclosure () throws -> Bool) throws { if try !value() { throw Failure.assertion } }
private final class Fixture {
    var now: Int64 = 1000
    lazy var holder = AuroraTailnetAuth { [unowned self] in self.now }
    lazy var owner = try! holder.beginOwner(sessionID: session, nodeGeneration: node)
    func begin() throws { _ = try holder.beginOwner(sessionID: session, nodeGeneration: node) }
    func offer(_ url: String = authURL) -> Bool { holder.receive(owner, identifier: identifier, typeID: 10, rawURL: url) }
    func open() -> (AuroraTailnetAuth.OpenResult?, [String]) {
        var values = [String]()
        guard let ticket = holder.requestOpen(owner, userGesture: true) else { return (nil, values) }
        let result = holder.dispatchOpen(ticket) { values.append($0) }
        return (result, values)
    }
}
@main private struct AuthTests {
    static func main() {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name)") }
        }
        // Validate the placeholder without a try! crash before executing vectors.
        test("owner-api") { let h = AuroraTailnetAuth { 0 }; _ = try h.beginOwner(sessionID: session, nodeGeneration: node) }
        if failed > 0 { print("auth: \(passed) passed, \(failed) failed"); exit(1) }
        for (index, url) in [authURL, "https://login.tailscale.com:443/a", "https://login.tailscale.com/a?next=%2F", "https://login.tailscale.com/a?q=[a]", "https://login.tailscale.com/a#[a]"].enumerated() {
            test("valid-https-\(index)") {
                let f = Fixture(); try check(f.offer(url)); try check(f.holder.authenticationRequired(f.owner))
                let result = f.open(); try check(result.0 == .opened && result.1 == [url])
                try check(f.open().1.isEmpty && !f.holder.authenticationRequired(f.owner))
            }
        }
        let rejected = [
            "https://login.tailscale.com/[a]",
            "http://login.tailscale.com/a", "https://login.tailscale.com.evil/a", "https://evil.example/login.tailscale.com/a",
            "https://user@login.tailscale.com/a", "https://@login.tailscale.com/a", "https://login.tailscale.com:444/a",
            "https://login.tailscale.com:/a", "https://login.tailscale.com./a", "https://LOGIN.TAILSCALE.COM/a",
            "HTTPS://login.tailscale.com/a", "https://login%2Etailscale.com/a", "https://login.tailscale.com\\@evil.example/a",
            " https://login.tailscale.com/a", "https://login.tailscale.com/a\n", "https://login.tailscale.com/a\u{00}",
            "https://login.tailscale.com/a\u{7f}", "https://login.tailscale.com/a\u{85}", "https://login.tailscale.com/a space",
            "https://login.tailscale.com/%zz", "https://login.tailscale.com/" + String(repeating: "a", count: 4096)]
        for (index, url) in rejected.enumerated() {
            test("invalid-url-\(index)") { let f = Fixture(); try check(!f.offer(url) && !f.holder.authenticationRequired(f.owner) && f.open().1.isEmpty) }
        }
        test("utf8-exact-boundary") {
            let f = Fixture(), url = "https://login.tailscale.com/" + String(repeating: "é", count: 2034)
            try check(url.utf8.count == 4096); try check(f.offer(url)); try check(!f.offer(url + "é")); try check(f.open().1 == [url])
        }
        test("exact-notification-category") {
            let f = Fixture()
            for (id, type) in [("other",10),(identifier,9),(identifier,11)] { try check(!f.holder.receive(f.owner, identifier: id, typeID: type, rawURL: authURL)) }
            try check(!f.holder.authenticationRequired(f.owner))
        }
        test("strict-uuid-safe-errors") {
            let f = Fixture(); try check(f.owner.sessionID == session && f.owner.nodeGeneration == node)
            for bad in ["", "1-1-1-1-1", session + "\n", "G" + session.dropFirst()] {
                for pair in [(bad,node),(session,bad)] {
                    do { _ = try f.holder.beginOwner(sessionID: pair.0, nodeGeneration: pair.1); throw Failure.assertion }
                    catch let error as AuroraTailnetAuthFailure { try check(error.rawValue == "invalid-arguments") }
                }
            }
            try check(f.offer())
        }
        test("explicit-gesture-only") {
            let f = Fixture(); _ = f.offer(); try check(f.holder.requestOpen(f.owner, userGesture: false) == nil); try check(f.open().0 == .opened)
        }
        test("one-ticket-and-no-replay") {
            let f = Fixture(); _ = f.offer(); let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
            try check(f.holder.requestOpen(f.owner, userGesture: true) == nil)
            var calls = 0; try check(f.holder.dispatchOpen(ticket) { _ in calls += 1 } == .opened)
            try check(f.holder.dispatchOpen(ticket) { _ in calls += 1 } == .unavailable && calls == 1)
        }
        test("ttl-rechecked-at-dispatch") {
            let f = Fixture(); _ = f.offer(); f.now += 299999; let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
            f.now += 1; var called = false
            try check(f.holder.dispatchOpen(ticket) { _ in called = true } == .unavailable && !called)
            try check(!f.holder.authenticationRequired(f.owner))
        }
        test("ttl-before-boundary") { let f = Fixture(); _ = f.offer(); f.now += 299999; try check(f.open().0 == .opened) }
        test("ttl-expires-before-request") { let f = Fixture(); _ = f.offer(); f.now += 300000; try check(f.holder.requestOpen(f.owner, userGesture: true) == nil) }
        for time: Int64 in [-1,999,Int64.max] {
            test("invalid-clock-\(time)") { let f = Fixture(); _ = f.offer(); f.now = time; try check(!f.holder.authenticationRequired(f.owner) && f.open().1.isEmpty) }
        }
        for lifecycle in ["stop","reload","forget"] {
            test("\(lifecycle)-revokes-dispatch") {
                let f = Fixture(); _ = f.offer(); let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
                f.holder.invalidate(f.owner); var called = false
                try check(f.holder.dispatchOpen(ticket) { _ in called = true } == .stale && !called)
                try check(!f.offer() && !f.holder.authenticationRequired(f.owner))
            }
        }
        test("same-uuid-new-owner-invalidates-old-platform") {
            let f = Fixture(); _ = f.offer(); let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
            let newer = try f.holder.beginOwner(sessionID: session, nodeGeneration: node)
            try check(!f.offer()); try check(f.holder.receive(newer, identifier: identifier, typeID: 10, rawURL: authURL))
            f.holder.invalidate(f.owner); try check(f.holder.dispatchOpen(ticket) { _ in } == .stale)
            try check(f.holder.requestOpen(newer, userGesture: true) != nil)
        }
        test("new-node-invalidates-old-request") {
            let f = Fixture(); _ = f.offer(); let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
            _ = try f.holder.beginOwner(sessionID: session, nodeGeneration: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
            try check(f.holder.dispatchOpen(ticket) { _ in } == .stale)
        }
        test("replacement-url-needs-new-gesture") {
            let f = Fixture(); _ = f.offer(); let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
            let newURL = "https://login.tailscale.com/new-public-fixture"; try check(f.offer(newURL))
            try check(f.holder.dispatchOpen(ticket) { _ in } == .unavailable); try check(f.open().1 == [newURL])
        }
        test("launch-failure-safe-and-consumed") {
            let f = Fixture(); _ = f.offer(); let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
            try check(f.holder.dispatchOpen(ticket) { _ in throw Failure.injected } == .unavailable)
            try check(f.holder.dispatchOpen(ticket) { _ in } == .unavailable)
            try check(!String(describing: ticket).contains("tailscale"))
        }
        test("foreign-holder-cannot-consume-ticket") {
            let f = Fixture(), other = Fixture(); _ = f.offer(); let ticket = f.holder.requestOpen(f.owner, userGesture: true)!
            try check(other.holder.dispatchOpen(ticket) { _ in } == .stale); try check(f.holder.dispatchOpen(ticket) { _ in } == .opened)
        }
        test("clock-failure-safe") {
            let holder = AuroraTailnetAuth { throw Failure.injected }
            let owner = try holder.beginOwner(sessionID: session, nodeGeneration: node)
            try check(!holder.receive(owner, identifier: identifier, typeID: 10, rawURL: authURL))
        }
        test("two-real-threads-launch-once") {
            let f = Fixture(); _ = f.offer(); let lock = NSLock(), group = DispatchGroup(), start = DispatchSemaphore(value: 0)
            var calls = 0
            for _ in 0..<2 { group.enter(); DispatchQueue.global().async {
                start.wait()
                if let ticket = f.holder.requestOpen(f.owner, userGesture: true) { _ = f.holder.dispatchOpen(ticket) { _ in lock.lock(); calls += 1; lock.unlock() } }
                group.leave()
            } }
            start.signal(); start.signal(); try check(group.wait(timeout: .now() + 3) == .success)
            lock.lock(); let actual = calls; lock.unlock(); try check(actual == 1)
        }
        print("auth: \(passed) passed, \(failed) failed"); exit(failed == 0 ? 0 : 1)
    }
}
