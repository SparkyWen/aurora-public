import Foundation
import Darwin

private enum TestFailure: Error { case assertion }
private func check(_ value: @autoclosure () throws -> Bool) throws { if try !value() { throw TestFailure.assertion } }
@main private struct ConfigTests {
    static let prepared = AuroraTailnetStore.Prepared(settingsGeneration: 1,
        nodeGeneration: "ABCDEF12-1234-1234-1234-ABCDEF123456",
        stateDirectory: "/private/public-fixture/aurora-tailnet/node-ABCDEF12-1234-1234-1234-ABCDEF123456", hostname: "aurora-abcdef12")
    static func fixture() -> [String: Any] { publicTailnetConfig(prepared) }
    static func encode(_ root: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), encoding: .utf8)!
    }
    static func main() {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name)") }
        }
        func rejects(_ name: String, _ edit: (inout [String: Any]) -> Void) {
            test(name) {
                var root = fixture(); edit(&root)
                do { _ = try AuroraTailnetConfig.validate(try encode(root), prepared: prepared); throw TestFailure.assertion }
                catch let error as AuroraTailnetConfigFailure { try check(error.rawValue == "invalid-state") }
            }
        }
        test("valid-private-native-endpoint") {
            let root = fixture(), normalized = try AuroraTailnetConfig.validate(try encode(fixture()), prepared: prepared)
            let actual = try JSONSerialization.jsonObject(with: Data(normalized.utf8)) as! NSDictionary
            try check(actual == root as NSDictionary)
        }
        for (field, value): (String, Any) in [
            ("state_directory", "/other/private/state"), ("hostname", "other-node"), ("detour", "direct"),
            ("system_interface", true), ("ephemeral", true), ("accept_routes", true), ("advertise_routes", ["10.0.0.0/8"]),
            ("advertise_exit_node", true), ("control_url", "https://example.invalid"), ("auth_key", "public-fixture"),
            ("system_interface", 0), ("accept_routes", 0), ("advertise_exit_node", NSNull())] {
            rejects("endpoint-rejects-\(field)-\(String(describing: type(of: value)))") { root in
                var endpoints = root["endpoints"] as! [[String: Any]]; endpoints[0][field] = value; root["endpoints"] = endpoints
            }
        }
        rejects("missing-endpoint") { $0.removeValue(forKey: "endpoints") }
        rejects("duplicate-endpoint") { $0["endpoints"] = ($0["endpoints"] as! [[String: Any]]) + ($0["endpoints"] as! [[String: Any]]) }
        rejects("unrelated-endpoint") { $0["endpoints"] = [["type": "wireguard", "tag": "aurora-tailnet"]] }
        rejects("log-cannot-persist-auth-links") { $0["log"] = ["level": "debug", "output": "/tmp/unwanted"] }
        rejects("log-types-strict") { $0["log"] = ["level": "warn", "timestamp": 1] }
        rejects("proxy-must-be-unique-selector") { $0["outbounds"] = [["type": "direct", "tag": "proxy"]] }
        for container in ["outbounds", "inbounds"] {
            rejects("reserved-tag-\(container)") { root in
                var rows = root[container] as! [[String: Any]]; rows.append(["type": "direct", "tag": "aurora-tailnet"]); root[container] = rows
            }
        }
        for field in ["endpoint", "accept_default_resolvers", "extra"] {
            rejects("dns-server-\(field)") { root in
                var dns = root["dns"] as! [String: Any], servers = dns["servers"] as! [[String: Any]]
                servers[1][field] = field == "endpoint" ? "other" : true; dns["servers"] = servers; root["dns"] = dns
            }
        }
        rejects("dns-must-route-ts-net-first") { root in
            var dns = root["dns"] as! [String: Any]; dns["rules"] = [["server": "dns-proxy"]] + (dns["rules"] as! [[String: Any]]); root["dns"] = dns
        }
        rejects("duplicate-tailnet-dns-server") { root in
            var dns = root["dns"] as! [String: Any], servers = dns["servers"] as! [[String: Any]]
            servers.append(servers[1]); dns["servers"] = servers; root["dns"] = dns
        }
        for index in 0..<4 {
            rejects("missing-route-prefix-\(index)") { root in
                var route = root["route"] as! [String: Any], rules = route["rules"] as! [[String: Any]]
                rules.remove(at: index); route["rules"] = rules; root["route"] = route
            }
        }
        rejects("route-before-inbound-reject") { root in
            var route = root["route"] as! [String: Any]; route["rules"] = [["action": "route", "outbound": "direct"]] + (route["rules"] as! [[String: Any]]); root["route"] = route
        }
        rejects("unknown-root-key") { $0["unexpected"] = true }
        rejects("missing-experimental-root-key") { $0.removeValue(forKey: "experimental") }
        rejects("tailnet-outbound-cannot-bypass-endpoint") { root in
            var rows = root["outbounds"] as! [[String: Any]]; rows.append(["type": "tailscale", "tag": "other"]); root["outbounds"] = rows
        }
        test("reserved-port-rejects-floating-point-spelling") {
            let json = try encode(fixture()).replacingOccurrences(of: "\"port\":[53]", with: "\"port\":[53.0]")
            try check(json.contains("[53.0]"))
            do { _ = try AuroraTailnetConfig.validate(json, prepared: prepared); throw TestFailure.assertion }
            catch let error as AuroraTailnetConfigFailure { try check(error.rawValue == "invalid-state") }
        }
        for raw in ["null", "[]", "true", "{", String(repeating: "x", count: 1_048_577)] {
            test("malformed-or-oversized-\(raw.utf8.count)") {
                do { _ = try AuroraTailnetConfig.validate(raw, prepared: prepared); throw TestFailure.assertion }
                catch let error as AuroraTailnetConfigFailure { try check(error.rawValue == "invalid-state") }
            }
        }
        print("config: \(passed) passed, \(failed) failed"); exit(failed == 0 ? 0 : 1)
    }
}
