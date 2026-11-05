package com.aurora.vpn.test

import android.content.Intent
import android.os.Handler
import com.aurora.vpn.*
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.Notification
import java.nio.file.Files

private class TailnetReply : AuroraTailnetChannel.Result {
    var value: Any? = null; var error: String? = null; var calls = 0
    override fun success(value: Any?) { this.value = value; calls++ }
    override fun error(code: String) { error = code; calls++ }
}
fun tailnetChannelTests() {
    fun case(name: String, body: (java.io.File, MutableList<() -> Unit>, MutableList<() -> Unit>,
              (String, Any?) -> TailnetReply, (Long) -> Unit, (Boolean) -> Unit, MutableList<String>) -> Unit) {
        val dir = Files.createTempDirectory("aurora-tailnet-channel-test-").toFile()
        val work = mutableListOf<() -> Unit>(); val post = mutableListOf<() -> Unit>()
        val launched = mutableListOf<String>(); var now = android.os.SystemClock.elapsedRealtime(); var foreground = true
        val channel = AuroraTailnetChannel(dir, { true }, { foreground },
            { _, generation, node -> launched.add("start:$generation:$node") }, { launched.add("browser") },
            { work.add(it) }, { post.add(it) }, { now })
        try {
            fun call(method: String, args: Any? = null): TailnetReply {
                val reply = TailnetReply()
                try { channel.handle(method, args, reply) } catch (_: Throwable) { reply.error("escaped") }
                return reply
            }
            body(dir, work, post, ::call, { now += it }, { foreground = it }, launched)
        } catch (error: Throwable) { expect(false, "$name: ${error.javaClass.simpleName}") }
        finally { Libbox.beforeCheckConfig = null; dir.deleteRecursively() }
    }
    fun drain(queue: MutableList<() -> Unit>) { while (queue.isNotEmpty()) queue.removeAt(0).invoke() }
    case("maintenance rejection finishes the fresh foreground-service request") { _, _, _, _, _, _, _ ->
        val fresh = AuroraVpnService(); val before = Libbox.servers.size
        AuroraVpnService.withTailnetMaintenance {
            fresh.onStartCommand(Intent().apply { action = AuroraVpnService.ACTION_START; putExtra(AuroraVpnService.EXTRA_CONFIG, "public-normal") }, 0, 17)
        }
        Handler.drain()
        expect(fresh.stopSelfResultCalls == 1 && Libbox.servers.size == before,
            "a refused fresh startForegroundService request is explicitly stopped before its OS foreground deadline")
    }
    case("capability uses current binary without setup or start") { dir, work, post, call, _, _, _ ->
        val servers = Libbox.servers.size; val setups = Libbox.setupCalls
        var checks = 0
        Libbox.beforeCheckConfig = { config -> checks++; check(config.contains("tailscale")) }
        val reply = call("capability", null)
        expect(reply.calls == 0 && checks == 0, "capability is deferred off the UI thread")
        drain(work); drain(post)
        expect(reply.value == true && checks == 1 && Libbox.servers.size == servers && Libbox.setupCalls == setups && dir.list()!!.isEmpty(),
            "capability checks current libbox tags without core setup, start, or state directory creation")
    }
    case("unsupported old binary remains unsupported") { _, work, post, call, _, _, _ ->
        Libbox.beforeCheckConfig = { throw IllegalStateException("public-native-message") }
        val reply = call("capability", null); drain(work); drain(post)
        expect(reply.value == false && reply.error == null, "native CheckConfig failure reports only false capability")
    }
    case("settings and prepare use native private directory") { dir, work, post, call, _, _, _ ->
        val read = call("readSettings", null); drain(work); drain(post)
        expect((read.value as? Map<*, *>)?.get("settingsGeneration") == 0L, "initial settings use strict schema and native generation")
        val enabled = call("setEnabled", mapOf("expectedGeneration" to 0, "enabled" to true)); drain(work); drain(post)
        expect((enabled.value as? Map<*, *>)?.get("settingsGeneration") == 1L, "small StandardMethodCodec int is accepted")
        val prepare = call("prepareStart", mapOf("expectedGeneration" to 1L)); drain(work); drain(post)
        val p = prepare.value as? Map<*, *>
        expect(p?.get("stateDirectory") is String && (p["stateDirectory"] as String).startsWith(dir.canonicalPath),
            "prepared path comes only from the native no-backup store")
    }
    case("invalid requests are rejected without worker or effects") { _, work, post, call, _, _, launched ->
        val invalid = listOf(
            "readSettings" to mapOf("extra" to 1),
            "setEnabled" to mapOf("expectedGeneration" to -1L, "enabled" to true),
            "setEnabled" to mapOf("expectedGeneration" to 1.0, "enabled" to true),
            "setEnabled" to mapOf("expectedGeneration" to 1L, "enabled" to "true"),
            "prepareStart" to mapOf("expectedGeneration" to Long.MAX_VALUE, "path" to "/untrusted"),
            "forget" to mapOf("nodeGeneration" to "not-a-uuid"),
            "start" to mapOf("settingsGeneration" to 0, "nodeGeneration" to "not-a-uuid", "config" to "x"),
            "openAuthentication" to mapOf("sessionId" to "bad", "nodeGeneration" to "bad"),
            "not-a-method" to null)
        for ((method,args) in invalid) {
            val r = call(method,args); drain(post)
            expect(r.error in setOf("invalid-state", "unsupported") && r.calls == 1,
                "malformed $method returns a fixed code without echoing input")
        }
        expect(work.isEmpty() && launched.isEmpty(), "invalid requests cannot touch storage or launch")
    }
    case("single flight has one worker and no automatic retry") { _, work, post, call, _, _, _ ->
        val first = call("readSettings",null); val second = call("readSettings",null)
        drain(post)
        expect(second.error == "busy" && work.size == 1, "concurrent caller gets busy without another queued mutation")
        drain(work); drain(post)
        expect(first.calls == 1 && first.error == null, "the original request completes exactly once")
    }
    case("deadline starts at native method receipt") { dir, work, post, call, advance, _, _ ->
        val r = call("setEnabled",mapOf("expectedGeneration" to 0, "enabled" to true))
        advance(4_000); drain(work); drain(post)
        expect(r.error == "stale" && dir.list()!!.isEmpty(), "a queued expired write cannot create storage or change settings")
    }
    case("worker failures never echo arbitrary native errors") { _, work, post, call, _, _, _ ->
        val r = call("setEnabled",mapOf("expectedGeneration" to 4L,"enabled" to true)); drain(work); drain(post)
        expect(r.error == "stale" && r.calls == 1, "store failures expose only stable public categories")
    }
    case("start is explicit and requires foreground") { _, _, post, call, _, foreground, launched ->
        val node = "ABCDEF12-1234-1234-1234-ABCDEF123456"
        val args = mapOf("settingsGeneration" to Long.MAX_VALUE,"nodeGeneration" to node,"config" to "public config")
        foreground(false); val denied = call("start",args); drain(post)
        expect(denied.error == "busy" && launched.isEmpty(), "background channel start does not launch a system VPN")
        foreground(true); val accepted = call("start",args); drain(post)
        expect(accepted.calls == 1 && accepted.error == null && accepted.value == null && launched == listOf("start:${Long.MAX_VALUE}:$node"),
            "explicit start preserves int64/UUID case and returns only dispatched, never connected")
    }
    case("safe disconnected snapshot and missing auth") { _, work, post, call, _, _, launched ->
        val r = call("snapshot",null); drain(work); drain(post)
        val p = r.value as? Map<*, *>
        expect(p?.get("schema") == 1 && p["tailnetStatus"] == "disabled" && p["authAvailable"] == false,
            "snapshot contains a bounded safe state and no auth URL")
        val auth = call("openAuthentication",mapOf("sessionId" to "ABCDEF12-1234-1234-1234-ABCDEF123456",
            "nodeGeneration" to "ABCDEF12-1234-1234-1234-ABCDEF123456")); drain(post)
        expect(auth.value == "stale" && launched.isEmpty(), "wrong or absent session cannot launch a browser")
    }
}
