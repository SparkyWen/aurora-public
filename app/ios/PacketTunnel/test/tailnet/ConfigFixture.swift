import Foundation

func publicTailnetConfig(_ prepared: AuroraTailnetStore.Prepared) -> [String: Any] {
        ["experimental": [:] as [String: Any], "log": ["level": "warn", "timestamp": true],
         "inbounds": [["type": "tun", "tag": "tun-in", "address": ["10.111.222.1/24"]]],
         "outbounds": [["type": "selector", "tag": "proxy", "outbounds": ["direct"]], ["type": "direct", "tag": "direct"]],
         "endpoints": [["type": "tailscale", "tag": "aurora-tailnet", "state_directory": prepared.stateDirectory,
                         "hostname": prepared.hostname, "system_interface": false, "ephemeral": false,
                         "accept_routes": false, "advertise_routes": [String](), "advertise_exit_node": false, "detour": "proxy"]],
         "dns": ["servers": [["type": "https", "tag": "dns-proxy", "server": "1.1.1.1"],
                              ["type": "tailscale", "tag": "dns-tailnet", "endpoint": "aurora-tailnet", "accept_default_resolvers": false]],
                 "rules": [["domain_suffix": ["ts.net"], "server": "dns-tailnet", "strategy": "prefer_ipv4"]]],
         "route": ["rules": [
            ["inbound": ["aurora-tailnet"], "action": "reject"],
            ["inbound": ["tun-in"], "network": ["tcp", "udp"], "port": [53], "action": "hijack-dns"],
            ["inbound": ["tun-in"], "ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], "outbound": "aurora-tailnet"],
            ["inbound": ["tun-in"], "domain_suffix": ["ts.net"], "outbound": "aurora-tailnet"]], "final": "proxy"]]
    }
