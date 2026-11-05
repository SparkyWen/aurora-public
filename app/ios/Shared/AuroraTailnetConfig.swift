import Foundation
import CoreFoundation

enum AuroraTailnetConfigFailure: String, Error { case invalidState = "invalid-state" }
enum AuroraTailnetConfig {
    // Native callers acquire the generation-bound lease before this check. Only
    // that prepared identity can be used by the core; public contract rules are
    // preserved after the reserved prefixes verified here.
    static func validate(_ json: String, prepared: AuroraTailnetStore.Prepared) throws -> String {
        func require(_ condition: Bool) throws { if !condition { throw AuroraTailnetConfigFailure.invalidState } }
        do {
            try require(json.utf8.count <= 1_048_576)
            guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let endpoints = root["endpoints"] as? [[String: Any]], let inbounds = root["inbounds"] as? [[String: Any]],
                  let outbounds = root["outbounds"] as? [[String: Any]], let dns = root["dns"] as? [String: Any],
                  let servers = dns["servers"] as? [[String: Any]], let dnsRules = dns["rules"] as? [[String: Any]],
                  let route = root["route"] as? [String: Any], let rules = route["rules"] as? [[String: Any]] else {
                throw AuroraTailnetConfigFailure.invalidState
            }
            try require(Set(root.keys) == ["log", "endpoints", "dns", "inbounds", "outbounds", "route", "experimental"])
            try require(same(root["log"], ["level": "warn", "timestamp": true]))
            let expected: [String: Any] = ["type": "tailscale", "tag": "aurora-tailnet", "state_directory": prepared.stateDirectory,
                "hostname": prepared.hostname, "system_interface": false, "ephemeral": false, "accept_routes": false,
                "advertise_routes": [String](), "advertise_exit_node": false, "detour": "proxy"]
            try require(endpoints.count == 1 && same(endpoints[0], expected))
            try require(inbounds.count == 1 && inbounds[0]["type"] as? String == "tun" && inbounds[0]["tag"] as? String == "tun-in")
            var selectors = 0
            for outbound in outbounds {
                try require(!["aurora-tailnet", "dns-tailnet"].contains(outbound["tag"] as? String ?? ""))
                try require(outbound["type"] as? String != "tailscale")
                if outbound["tag"] as? String == "proxy" {
                    try require(outbound["type"] as? String == "selector"); selectors += 1
                }
            }
            try require(selectors == 1)
            let expectedDNS: [String: Any] = ["type": "tailscale", "tag": "dns-tailnet", "endpoint": "aurora-tailnet", "accept_default_resolvers": false]
            var tailnetDNS = 0
            for server in servers {
                if server["tag"] as? String == "dns-tailnet" || server["type"] as? String == "tailscale" {
                    try require(same(server, expectedDNS)); tailnetDNS += 1
                } else { try require(server["tag"] as? String != "aurora-tailnet") }
            }
            try require(tailnetDNS == 1)
            try require(same(dnsRules.first, ["domain_suffix": ["ts.net"], "server": "dns-tailnet", "strategy": "prefer_ipv4"]))
            let expectedRules: [[String: Any]] = [
                ["inbound": ["aurora-tailnet"], "action": "reject"],
                ["inbound": ["tun-in"], "network": ["tcp", "udp"], "port": [53], "action": "hijack-dns"],
                ["inbound": ["tun-in"], "ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], "outbound": "aurora-tailnet"],
                ["inbound": ["tun-in"], "domain_suffix": ["ts.net"], "outbound": "aurora-tailnet"]]
            try require(rules.count >= 4)
            for index in 0..<4 { try require(same(rules[index], expectedRules[index])) }
            // Pass exactly this parsed tree to Go, never the original JSON whose
            // duplicate keys or number spellings another parser could interpret.
            let encoded = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            guard let result = String(data: encoded, encoding: .utf8) else { throw AuroraTailnetConfigFailure.invalidState }
            return result
        } catch { throw AuroraTailnetConfigFailure.invalidState }
    }
    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if let a = lhs as? [String: Any], let b = rhs as? [String: Any] {
            return Set(a.keys) == Set(b.keys) && a.keys.allSatisfy { same(a[$0], b[$0]) }
        }
        if let a = lhs as? [Any], let b = rhs as? [Any] {
            return a.count == b.count && zip(a,b).allSatisfy { same($0,$1) }
        }
        if let a = lhs as? String, let b = rhs as? String { return a == b }
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            let boolA = CFGetTypeID(a) == CFBooleanGetTypeID(), boolB = CFGetTypeID(b) == CFBooleanGetTypeID()
            guard boolA == boolB else { return false }
            if boolA { return a.boolValue == b.boolValue }
            // Reserved numeric fields are integers; do not coerce 53.0 into 53.
            guard !["d", "f"].contains(String(cString: a.objCType)), !["d", "f"].contains(String(cString: b.objCType)) else { return false }
            return a.stringValue == b.stringValue
        }
        return lhs is NSNull && rhs is NSNull
    }
}
