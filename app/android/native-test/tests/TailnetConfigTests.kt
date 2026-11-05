package com.aurora.vpn.test

import com.aurora.vpn.AuroraTailnetConfig
import com.aurora.vpn.AuroraTailnetStore
import com.aurora.vpn.AuroraTailnetStoreFailure
import org.json.JSONArray
import org.json.JSONObject

fun publicTailnetConfig(p: AuroraTailnetStore.Prepared): String = """{
 "log":{"level":"warn","timestamp":true},
 "endpoints":[{"type":"tailscale","tag":"aurora-tailnet","state_directory":${JSONObject.quote(p.stateDirectory)},
   "hostname":${JSONObject.quote(p.hostname)},"system_interface":false,"ephemeral":false,"accept_routes":false,
   "advertise_routes":[],"advertise_exit_node":false,"detour":"proxy"}],
 "dns":{"servers":[{"type":"local","tag":"dns-direct"},{"type":"tailscale","tag":"dns-tailnet",
   "endpoint":"aurora-tailnet","accept_default_resolvers":false}],
   "rules":[{"domain_suffix":["ts.net"],"server":"dns-tailnet","strategy":"prefer_ipv4"}]},
 "inbounds":[{"type":"tun","tag":"tun-in"}],
 "outbounds":[{"type":"direct","tag":"direct"},{"type":"selector","tag":"proxy","outbounds":["direct"]}],
 "route":{"rules":[{"inbound":["aurora-tailnet"],"action":"reject"},
   {"inbound":["tun-in"],"network":["tcp","udp"],"port":[53],"action":"hijack-dns"},
   {"inbound":["tun-in"],"ip_cidr":["100.64.0.0/10","fd7a:115c:a1e0::/48"],"outbound":"aurora-tailnet"},
   {"inbound":["tun-in"],"domain_suffix":["ts.net"],"outbound":"aurora-tailnet"}],"final":"proxy"},
 "experimental":{"cache_file":{"enabled":false}}
}"""

fun tailnetConfigTests() {
    val prepared = AuroraTailnetStore.Prepared(3, "ABCDEF12-1234-1234-1234-ABCDEF123456",
        "/private/public-fixture/node-ABCDEF12", "aurora-abcdef12")
    fun case(name: String, body: () -> Unit) {
        try { body() } catch (error: Throwable) { expect(false, "$name: ${error.javaClass.simpleName}") }
    }
    fun refused(config: String): Boolean = try { AuroraTailnetConfig.validate(config, prepared); false }
        catch (e: AuroraTailnetStoreFailure) { e.code == "invalid-state" && e.message == "invalid-state" }
    fun bad(name: String, change: (JSONObject) -> Unit) = case(name) {
        val config = JSONObject(publicTailnetConfig(prepared)); change(config)
        expect(refused(config.toString()), "$name rejected before native core admission")
    }
    case("native context and reserved routes accepted") {
        val original = publicTailnetConfig(prepared)
        val validated = AuroraTailnetConfig.validate(original, prepared)
        expect(JSONObject(validated).getJSONArray("endpoints").getJSONObject(0).getString("state_directory") == prepared.stateDirectory,
            "validated JSON preserves only the native-owned state directory")
        expect(validated != original && JSONObject(validated).getJSONObject("route").getString("final") == "proxy",
            "the same parsed and validated tree is reserialized without changing public policy")
    }
    for ((key, value) in listOf<Pair<String, Any>>("state_directory" to "/wrong-node", "hostname" to "wrong-node",
        "system_interface" to true, "ephemeral" to true, "accept_routes" to true,
        "advertise_exit_node" to true, "detour" to "direct", "tag" to "other", "type" to "direct",
        "control_url" to "https://public-fixture.invalid", "auth_key" to "public-fixture", "exit_node" to "public-fixture")) {
        bad("endpoint field $key") { it.getJSONArray("endpoints").getJSONObject(0).put(key, value) }
    }
    bad("subnet advertisement") { it.getJSONArray("endpoints").getJSONObject(0).put("advertise_routes", JSONArray().put("10.0.0.0/8")) }
    bad("wrong boolean type") { it.getJSONArray("endpoints").getJSONObject(0).put("system_interface", "false") }
    bad("multiple endpoint owners") { it.getJSONArray("endpoints").put(it.getJSONArray("endpoints").getJSONObject(0)) }
    bad("missing endpoint") { it.remove("endpoints") }
    bad("debug logs forbidden") { it.getJSONObject("log").put("level", "debug") }
    bad("file logs forbidden") { it.getJSONObject("log").put("output", "/private/public-fixture.log") }
    bad("unknown top-level service forbidden") { it.put("services", JSONArray()) }
    bad("first inbound reject cannot be missing") { it.getJSONObject("route").getJSONArray("rules").remove(0) }
    bad("first inbound reject cannot be bypassed") { it.getJSONObject("route").getJSONArray("rules").getJSONObject(0).put("inbound", JSONArray().put("wrong")) }
    bad("conditional inbound reject forbidden") { it.getJSONObject("route").getJSONArray("rules").getJSONObject(0).put("network", JSONArray().put("tcp")) }
    bad("TUN DNS hijack required") { it.getJSONObject("route").getJSONArray("rules").getJSONObject(1).put("action", "route") }
    bad("Tailnet CIDRs cannot be widened") { it.getJSONObject("route").getJSONArray("rules").getJSONObject(2).put("ip_cidr", JSONArray().put("0.0.0.0/0")) }
    bad("Tailnet domain route required") { it.getJSONObject("route").getJSONArray("rules").getJSONObject(3).put("outbound", "direct") }
    bad("Tailnet DNS must be first") { it.getJSONObject("dns").getJSONArray("rules").getJSONObject(0).put("domain_suffix", JSONArray().put("other.invalid")) }
    bad("Tailnet DNS cannot fall back to public server") { it.getJSONObject("dns").getJSONArray("rules").getJSONObject(0).put("server", "dns-direct") }
    bad("Tailnet DNS endpoint reference bound") { it.getJSONObject("dns").getJSONArray("servers").getJSONObject(1).put("endpoint", "wrong") }
    bad("Tailnet DNS default resolvers disabled") { it.getJSONObject("dns").getJSONArray("servers").getJSONObject(1).put("accept_default_resolvers", true) }
    bad("Tailnet DNS extra controls forbidden") { it.getJSONObject("dns").getJSONArray("servers").getJSONObject(1).put("detour", "direct") }
    bad("reserved DNS tag duplicate") { it.getJSONObject("dns").getJSONArray("servers").getJSONObject(0).put("tag", "dns-tailnet") }
    bad("proxy must be a selector") { it.getJSONArray("outbounds").getJSONObject(1).put("type", "direct") }
    bad("reserved endpoint tag collision") { it.getJSONArray("outbounds").getJSONObject(0).put("tag", "aurora-tailnet") }
    bad("TUN inbound identity required") { it.getJSONArray("inbounds").getJSONObject(0).put("tag", "not-tun") }
    case("malformed config errors contain no input") {
        expect(refused("public-fixture malformed JSON"), "parse failure has only fixed invalid-state category")
        expect(refused(" ".repeat(1_048_577)), "oversized config rejected before parsing")
    }
}
