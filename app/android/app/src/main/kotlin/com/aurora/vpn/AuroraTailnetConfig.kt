package com.aurora.vpn

import org.json.JSONArray
import org.json.JSONObject

// Re-check native-owned identity and the compiler's reserved Tailnet rules at
// the engine boundary. The rest of the public contract policy stays intact.
object AuroraTailnetConfig {
    fun validate(config: String, prepared: AuroraTailnetStore.Prepared): String {
        try {
            require(config.length <= 1_048_576 && config.toByteArray(Charsets.UTF_8).size <= 1_048_576)
            val root = JSONObject(config)
            require(keys(root) == setOf("log", "endpoints", "dns", "inbounds", "outbounds", "route", "experimental"))
            require(same(root.getJSONObject("log"), JSONObject("""{"level":"warn","timestamp":true}""")))
            val expected = JSONObject("""{"type":"tailscale","tag":"aurora-tailnet",
                "state_directory":${JSONObject.quote(prepared.stateDirectory)},"hostname":${JSONObject.quote(prepared.hostname)},
                "system_interface":false,"ephemeral":false,"accept_routes":false,"advertise_routes":[],
                "advertise_exit_node":false,"detour":"proxy"}""")
            val endpoints = root.getJSONArray("endpoints")
            require(endpoints.length() == 1 && same(endpoints.getJSONObject(0), expected))
            val inbounds = root.getJSONArray("inbounds")
            require(inbounds.length() == 1 && inbounds.getJSONObject(0).get("type") == "tun" &&
                inbounds.getJSONObject(0).get("tag") == "tun-in")
            val outbounds = root.getJSONArray("outbounds")
            var selectors = 0
            for (index in 0 until outbounds.length()) {
                val outbound = outbounds.getJSONObject(index)
                require(outbound.opt("tag") !in setOf("aurora-tailnet", "dns-tailnet"))
                require(outbound.opt("type") != "tailscale")
                if (outbound.opt("tag") == "proxy") {
                    require(outbound.get("type") == "selector")
                    selectors++
                }
            }
            require(selectors == 1)
            val dns = root.getJSONObject("dns")
            val servers = dns.getJSONArray("servers")
            val expectedDNS = JSONObject("""{"type":"tailscale","tag":"dns-tailnet",
                "endpoint":"aurora-tailnet","accept_default_resolvers":false}""")
            var tailnetDNS = 0
            for (index in 0 until servers.length()) {
                val server = servers.getJSONObject(index)
                if (server.opt("tag") == "dns-tailnet" || server.opt("type") == "tailscale") {
                    require(same(server, expectedDNS)); tailnetDNS++
                } else require(server.opt("tag") != "aurora-tailnet")
            }
            require(tailnetDNS == 1)
            require(same(dns.getJSONArray("rules").getJSONObject(0), JSONObject("""{
                "domain_suffix":["ts.net"],"server":"dns-tailnet","strategy":"prefer_ipv4"}""")))
            val rules = root.getJSONObject("route").getJSONArray("rules")
            val expectedRules = JSONArray("""[
                {"inbound":["aurora-tailnet"],"action":"reject"},
                {"inbound":["tun-in"],"network":["tcp","udp"],"port":[53],"action":"hijack-dns"},
                {"inbound":["tun-in"],"ip_cidr":["100.64.0.0/10","fd7a:115c:a1e0::/48"],"outbound":"aurora-tailnet"},
                {"inbound":["tun-in"],"domain_suffix":["ts.net"],"outbound":"aurora-tailnet"}]""")
            require(rules.length() >= 4)
            for (index in 0..3) require(same(rules.get(index), expectedRules.get(index)))
            // Go receives this exact parsed tree, not the original spelling.
            // This also prevents a parser difference over duplicate key spelling
            // from changing the endpoint after native validation.
            return root.toString()
        } catch (_: Exception) { throw AuroraTailnetStoreFailure("invalid-state") }
    }

    private fun keys(value: JSONObject): Set<String> = value.keys().asSequence().toSet()
    private fun same(left: Any, right: Any): Boolean = when {
        left is JSONObject && right is JSONObject -> keys(left) == keys(right) && keys(left).all { same(left.get(it), right.get(it)) }
        left is JSONArray && right is JSONArray -> left.length() == right.length() && (0 until left.length()).all { same(left.get(it), right.get(it)) }
        else -> left == right
    }
}
