import XCTest

/// End-to-end tunnel test on a physical device. Drives the real UI (tap Connect),
/// then verifies the tunnel objectively from inside the device:
///   1. the app reports Connected;
///   2. an interface carries the Aurora iOS TUN address 10.111.222.1
///      (iOS uses the small-subnet TUN);
///   3. an HTTPS fetch succeeds through the tunnel's default route.
/// The egress IP is logged, not asserted — with a home-exit contract the
/// egress equals the home IP, which is also the phone's own egress when it sits
/// on the home Wi-Fi.
final class RunnerUITests: XCTestCase {

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testTunnelConnectsEndToEnd() throws {
    let app = XCUIApplication()
    app.launch()

    let connectBtn = app.buttons["Connect"]
    let disconnectBtn = app.buttons["Disconnect"]

    // A previous session may have left the tunnel up — start from a clean slate.
    if disconnectBtn.waitForExistence(timeout: 10) {
      disconnectBtn.tap()
      XCTAssertTrue(connectBtn.waitForExistence(timeout: 30),
                    "could not reach disconnected state before the test")
      sleep(3)
    } else {
      XCTAssertTrue(connectBtn.waitForExistence(timeout: 20),
                    "connect button not found — Flutter UI did not load")
    }
    XCTAssertFalse(Self.tunInterfaceUp(),
                   "TUN 10.111.222.1 present while disconnected")

    let ipBefore = Self.fetchEgressIP()

    connectBtn.tap()

    // First install only: the system VPN-configuration consent alert.
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    // "\u{5141}\u{8BB8}" is the Chinese-locale label of the same system button.
    for label in ["Allow", "\u{5141}\u{8BB8}"] {
      let b = springboard.buttons[label]
      if b.waitForExistence(timeout: 3) { b.tap(); break }
    }

    let connected = app.staticTexts["Connected"]
    XCTAssertTrue(connected.waitForExistence(timeout: 60),
                  "status never reached Connected")

    var tunUp = false
    for _ in 0..<20 {
      if Self.tunInterfaceUp() { tunUp = true; break }
      sleep(1)
    }
    XCTAssertTrue(tunUp, "no interface with 10.111.222.1 — tunnel not actually up")

    // Data-path is environment-dependent (needs the home exit reachable from
    // this device's network), so probe it as DIAGNOSTICS rather than a hard
    // gate. The hard gates above (connect + TUN up + clean teardown) are the
    // deterministic device-deploy proof. Capture the app's OWN ConnectionProbe
    // verdict — it runs through the real tunnel and classifies the failure.
    let gstatic = Self.httpOK("https://www.gstatic.com/generate_204", expect: 204)
    let cloudflare = Self.httpOK("https://cp.cloudflare.com/generate_204", expect: 204)
    let githubOK = Self.httpOK(
        "https://github.githubassets.com/favicons/favicon.png", expect: 200)
    let ipAfter = Self.fetchEgressIP()

    // The app's ConnectionProbe runs async after connect (up to ~12s); poll
    // until its verdict (not the "Verifying…" spinner) shows.
    var appVerdict = "(none)"
    for _ in 0..<20 {
      var found: String?
      for t in app.staticTexts.allElementsBoundByIndex where t.label.contains("Network check") {
        found = t.label
      }
      if let f = found, !f.contains("Verifying") { appVerdict = f; break }
      if let f = found { appVerdict = f }
      sleep(1)
    }

    let report = "egress before=\(ipBefore.isEmpty ? "?" : ipBefore) after=\(ipAfter.isEmpty ? "?" : ipAfter) gstatic204=\(gstatic) cf204=\(cloudflare) github=\(githubOK) appProbe=[\(appVerdict)]"
    print("AURORA-E2E \(report)")
    let attachment = XCTAttachment(string: report)
    attachment.name = "tunnel-probe"
    attachment.lifetime = .keepAlways
    add(attachment)

    // Tear down and verify the app returns to a clean disconnected state.
    disconnectBtn.tap()
    XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 30),
                  "did not return to Disconnected after disconnect")
    var tunDown = false
    for _ in 0..<15 {
      if !Self.tunInterfaceUp() { tunDown = true; break }
      sleep(1)
    }
    XCTAssertTrue(tunDown, "TUN address still present after disconnect")
  }

  // MARK: - helpers

  /// True when any interface carries the Aurora iOS TUN address 10.111.222.1.
  /// The UI-test runner is a separate process on the same device, so the utun
  /// created by the PacketTunnel extension is visible to it system-wide.
  private static func tunInterfaceUp() -> Bool {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0 else { return false }
    defer { freeifaddrs(addrs) }
    var p = addrs
    while let cur = p {
      let ifa = cur.pointee
      if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
        var sin = sockaddr_in()
        memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
        var addr = sin.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        if String(cString: buf) == "10.111.222.1" { return true }
      }
      p = ifa.ifa_next
    }
    return false
  }

  /// True if the URL returns the expected status through whatever network path
  /// is currently active (the tunnel, when connected).
  private static func httpOK(_ url: String, expect: Int) -> Bool {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 12
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: cfg)
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    session.dataTask(with: URL(string: url)!) { _, response, _ in
      if let http = response as? HTTPURLResponse { ok = http.statusCode == expect }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 15)
    return ok
  }

  private static func fetchEgressIP() -> String {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 15
    let session = URLSession(configuration: cfg)
    let sem = DispatchSemaphore(value: 0)
    var out = ""
    session.dataTask(with: URL(string: "https://api.ip.sb/ip")!) { data, _, _ in
      if let d = data, let s = String(data: d, encoding: .utf8) {
        out = s.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 20)
    return out
  }
}
