import Foundation
import NetworkExtension

// Exercised against the real NetworkExtension SDK: the token mapping is the
// contract `ConnectFlow._explainStartFailure` keys on, so a renamed case or a
// changed raw value must fail here, not on a user's screen.
var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("FAIL: \(what)") } else { print("ok: \(what)") }
}

// The message below is a localized (Chinese) system string, written with \u escapes so
// the test still exercises non-ASCII text handling.
if #available(macOS 13.0, iOS 16.0, *) {
    let noNetwork = NSError(
        domain: NEVPNConnectionErrorDomain,
        code: NEVPNConnectionError.noNetworkAvailable.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "VPN\u{4F1A}\u{8BDD}\u{5DF2}\u{65AD}\u{5F00}\u{8FDE}\u{63A5}\u{FF0C}\u{56E0}\u{4E3A}\u{8BBE}\u{5907}\u{672A}\u{63A5}\u{5165}\u{7F51}\u{7EDC}\u{3002}"]
    )
    let described = AuroraDisconnectReason.describe(noNetwork)
    check(described.hasPrefix("ne_disconnect[no_network_available] (NEVPNConnectionErrorDomain "), described)
    check(described.hasSuffix("): VPN\u{4F1A}\u{8BDD}\u{5DF2}\u{65AD}\u{5F00}\u{8FDE}\u{63A5}\u{FF0C}\u{56E0}\u{4E3A}\u{8BBE}\u{5907}\u{672A}\u{63A5}\u{5165}\u{7F51}\u{7EDC}\u{3002}"), "localized text preserved")
    check(
        AuroraDisconnectReason.token(
            domain: NEVPNConnectionErrorDomain,
            code: NEVPNConnectionError.unrecoverableNetworkChange.rawValue
        ) == "unrecoverable_network_change",
        "network change token"
    )
}
check(
    AuroraDisconnectReason.token(domain: "NEVPNErrorDomain", code: 4) == "nevpnerrordomain_4",
    "unknown domains fall back to domain_code"
)
check(
    AuroraDisconnectReason.token(domain: "com.apple.foo.Bar", code: 9) == "bar_9",
    "dotted domains keep their last component"
)
if failures > 0 { exit(1) }
