package com.aurora.vpn.test

import android.content.Intent
import android.os.Handler
import com.aurora.vpn.AuroraState
import com.aurora.vpn.AuroraTailnetStore
import com.aurora.vpn.AuroraVpnService
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.Notification
import java.nio.file.Files
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private fun stopTailnetService(service: AuroraVpnService) {
    service.onStartCommand(Intent().apply { action = AuroraVpnService.ACTION_STOP }, 0, 2)
}
private fun startTailnetService(service: AuroraVpnService, p: AuroraTailnetStore.Prepared,
                                generation: Long = p.settingsGeneration, config: String = publicTailnetConfig(p)) {
    service.onStartCommand(Intent().apply {
        action = AuroraVpnService.ACTION_START
        putExtra(AuroraVpnService.EXTRA_CONFIG, config)
        putExtra(AuroraVpnService.EXTRA_TAILNET_GENERATION, generation)
        putExtra(AuroraVpnService.EXTRA_TAILNET_NODE, p.nodeGeneration)
    }, 0, 1)
}
private fun notification() = Notification().apply {
    setIdentifier("tailscale-authentication"); setTypeID(10)
    setOpenURL("https://login.tailscale.com/a/public-service-fixture")
}

fun tailnetIntegrationTests() {
    fun case(name: String, body: (AuroraVpnService, AuroraTailnetStore, AuroraTailnetStore.Prepared) -> Unit) {
        val root = Files.createTempDirectory("aurora-tailnet-service-test-").toFile()
        val service = AuroraVpnService().apply { noBackupFilesDir = root }
        val store = AuroraTailnetStore(root)
        try {
            store.setEnabled(0, true) { true }
            val prepared = store.prepareStart(1)!!
            Libbox.beforeStart = null; Libbox.afterStart = null; Libbox.beforeClose = null
            Libbox.servers.clear()
            body(service, store, prepared)
        } catch (error: Throwable) {
            expect(false, "$name: ${error.javaClass.simpleName}")
        } finally {
            Libbox.beforeStart = null; Libbox.afterStart = null; Libbox.beforeClose = null
            stopTailnetService(service)
            awaitCondition("Tailnet fixture stopped") { AuroraState.status == "disconnected" }
            root.deleteRecursively()
        }
    }
    case("active core owns its exact private node lease") { service, store, prepared ->
        startTailnetService(service, prepared)
        awaitCondition("Tailnet connected") { AuroraState.status == "connected" }
        expect(store.forget(prepared.nodeGeneration) { true } == "busy", "even a mistaken stopped caller cannot erase an active core's node")
    }
    case("ordinary start cannot bypass Tailnet node ownership") { service, _, prepared ->
        service.onStartCommand(Intent().apply {
            action = AuroraVpnService.ACTION_START
            putExtra(AuroraVpnService.EXTRA_CONFIG, publicTailnetConfig(prepared))
        }, 0, 1)
        awaitCondition("ordinary Tailnet payload refused") { AuroraState.status in setOf("error", "connected") }
        expect(Libbox.servers.isEmpty() && !AuroraVpnService.running,
            "Tailnet JSON on the ordinary start method cannot bypass native lease and generation checks")
    }
    case("replacement Service cannot take an active Tailnet session") { service, _, prepared ->
        startTailnetService(service, prepared)
        awaitCondition("original Tailnet connected") { AuroraState.status == "connected" }
        val id = AuroraVpnService.sessionSnapshot()["sessionId"]
        val replacement = AuroraVpnService().apply { noBackupFilesDir = service.noBackupFilesDir }
        startTailnetService(replacement, prepared)
        Handler.drain()
        expect(AuroraVpnService.sessionSnapshot()["sessionId"] == id && AuroraVpnService.running,
            "a new Service request must not overwrite the current live owner")
        expect(replacement.stopSelfResultCalls == 1 && service.stopSelfResultCalls == 0,
            "a rejected replacement stops only its own fresh foreground-service request")
        stopTailnetService(replacement)
    }
    case("channel forget preserves busy as a typed result") { service, _, prepared ->
        startTailnetService(service, prepared)
        awaitCondition("channel forget active core") { AuroraState.status == "connected" }
        var answer: Any? = null; var error: String? = null
        val channel = com.aurora.vpn.AuroraTailnetChannel(service.noBackupFilesDir, { true }, { true },
            { _, _, _ -> }, {}, { it() }, { it() })
        channel.handle("forget", mapOf("nodeGeneration" to prepared.nodeGeneration), object : com.aurora.vpn.AuroraTailnetChannel.Result {
            override fun success(value: Any?) { answer = value }
            override fun error(code: String) { error = code }
        })
        expect(answer == "busy" && error == null, "forget returns the protocol busy value while a real session owns its lease")
    }
    case("stale generation is rejected before any Go server") { service, _, prepared ->
        startTailnetService(service, prepared, generation = 2)
        awaitCondition("stale startup reports failure") { AuroraState.status in setOf("error", "connected") }
        expect(Libbox.servers.isEmpty() && !AuroraVpnService.running, "queued stale settings cannot reach native server creation")
    }
    case("tampered native-owned endpoint rejected before Go") { service, _, prepared ->
        startTailnetService(service, prepared, config = publicTailnetConfig(prepared).replace(prepared.hostname, "wrong-host"))
        awaitCondition("invalid config reports failure") { AuroraState.status in setOf("error", "connected") }
        expect(Libbox.servers.isEmpty() && !AuroraVpnService.running, "Dart config cannot replace native Tailnet identity")
    }
    case("cancelled is not proof that a node is closed") { service, store, prepared ->
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        startTailnetService(service, prepared)
        awaitCondition("Tailnet connected before close") { AuroraState.status == "connected" }
        Libbox.beforeClose = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
        val retiringID = AuroraVpnService.tailnetSnapshot()?.get("sessionId")
        try {
            stopTailnetService(service)
            check(entered.await(3, TimeUnit.SECONDS))
            expect(store.forget(prepared.nodeGeneration) { true } == "busy", "lease is retained while close blocks after cancellation")
            startTailnetService(service, prepared)
            expect(AuroraVpnService.tailnetSnapshot()?.get("sessionId") == retiringID,
                "the same Service cannot replace a cancelled owner whose real close has not completed")
        } finally { release.countDown() }
        awaitCondition("Tailnet real close completes") { AuroraState.status == "disconnected" }
        expect(store.forget(prepared.nodeGeneration) { true } == "forgotten", "only actual close completion releases the node")
    }
    case("Tailnet reload replaces callback owner but keeps VPN UUID and lease") { service, store, prepared ->
        startTailnetService(service, prepared)
        awaitCondition("Tailnet connected before reload") { AuroraState.status == "connected" }
        val old = Libbox.servers.single(); val id = AuroraVpnService.sessionSnapshot()["sessionId"] as String
        old.platform.sendNotification(notification())
        expect(AuroraVpnService.tailnetSnapshot()?.get("authAvailable") == true, "current platform notification exposes safe auth state")
        var result: String? = null
        AuroraVpnService.reloadCurrentSession(id) { result = it }
        awaitCondition("Tailnet reload completed") { result != null }
        expect(result == "reloaded" && AuroraVpnService.sessionSnapshot()["sessionId"] == id,
            "Tailnet reload reuses the existing VPN session")
        expect(Libbox.servers.size == 2 && old.closed && Libbox.servers.last().platform !== old.platform,
            "Tailnet reload creates a fresh native callback owner after confirmed old close")
        expect(store.forget(prepared.nodeGeneration) { true } == "busy", "same node lease stays held across reload")
        old.platform.sendNotification(notification()); old.handler.serviceStop(); Handler.drain()
        expect(AuroraVpnService.running && AuroraVpnService.tailnetSnapshot()?.get("authAvailable") == false,
            "late old notification and serviceStop cannot act on the new core")
        Libbox.servers.last().platform.sendNotification(notification())
        expect(AuroraVpnService.tailnetSnapshot()?.get("authAvailable") == true, "new platform has its own fresh authentication owner")
    }
    case("retired platform cannot replace the new TUN after a delayed builder") { service, _, prepared ->
        startTailnetService(service, prepared)
        awaitCondition("TUN callback initially connected") { AuroraState.status == "connected" }
        val old = Libbox.servers.last()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val failed = java.util.concurrent.atomic.AtomicBoolean(false)
        android.net.VpnService.beforeEstablish = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
        val callback = Thread {
            try { old.platform.openTun(io.nekohasekai.libbox.TunOptions()) } catch (_: Exception) { failed.set(true) }
        }
        try {
            callback.start(); check(entered.await(3, TimeUnit.SECONDS))
            android.net.VpnService.beforeEstablish = null
            var result: String? = null
            AuroraVpnService.reloadCurrentSession(AuroraVpnService.sessionSnapshot()["sessionId"] as String) { result = it }
            awaitCondition("new platform's TUN ready") { result != null }
            val currentFd = android.net.VpnService.established.last()
            release.countDown(); callback.join(3_000)
            expect(failed.get() && !currentFd.closed,
                "a late old platform TUN must close its own descriptor, never overwrite or close the new generation FD")
        } finally { android.net.VpnService.beforeEstablish = null; release.countDown(); callback.join(3_000) }
    }
    for (mode in listOf("opened", "expired", "background", "reload", "replacement-url", "sink-failed")) {
        case("auth dispatch binds $mode to original native owner") { service, _, prepared ->
            startTailnetService(service, prepared)
            awaitCondition("auth dispatch initially connected") { AuroraState.status == "connected" }
            val id = AuroraVpnService.sessionSnapshot()["sessionId"] as String
            Libbox.servers.last().platform.sendNotification(notification())
            val posts = mutableListOf<() -> Unit>(); var now = android.os.SystemClock.elapsedRealtime()
            var foreground = true; var launches = 0; var answer: Any? = null; var error: String? = null
            val channel = com.aurora.vpn.AuroraTailnetChannel(service.noBackupFilesDir, { true }, { foreground },
                { _, _, _ -> error = "unexpected-start" }, { launches++; if (mode == "sink-failed") throw IllegalStateException("public-browser-failure") },
                { it() }, { posts.add(it) }, { now })
            val reply = object : com.aurora.vpn.AuroraTailnetChannel.Result {
                override fun success(value: Any?) { answer = value }
                override fun error(code: String) { error = code }
            }
            channel.handle("openAuthentication", mapOf("sessionId" to id, "nodeGeneration" to prepared.nodeGeneration), reply)
            when (mode) {
                "expired" -> now += 4_000
                "background" -> foreground = false
                "replacement-url" -> Libbox.servers.last().platform.sendNotification(notification())
                "reload" -> {
                    var reload: String? = null
                    AuroraVpnService.reloadCurrentSession(id) { reload = it }
                    awaitCondition("queued auth owner replaced") { reload != null }
                    Libbox.servers.last().platform.sendNotification(notification())
                }
            }
            while (posts.isNotEmpty()) posts.removeAt(0).invoke()
            val expected = when (mode) { "opened" -> "opened"; "reload" -> "stale"; else -> "unavailable" }
            expect(answer == expected && error == null, "queued $mode auth dispatch returns only the fixed result")
            expect(launches == if (mode in setOf("opened", "sink-failed")) 1 else 0,
                "queued $mode auth dispatch must not launch a stale browser")
            if (mode == "opened" || mode == "sink-failed") {
                channel.handle("openAuthentication", mapOf("sessionId" to id, "nodeGeneration" to prepared.nodeGeneration), reply)
                while (posts.isNotEmpty()) posts.removeAt(0).invoke()
                expect(answer == "unavailable" && launches == 1, "successful and failed native launch both consume the ticket once")
            }
        }
    }
    case("Tailnet core failures do not escape to OS logs") { service, _, prepared ->
        android.util.Log.records.clear()
        Libbox.beforeStart = { server ->
            server.handler.writeDebugMessage("https://login.tailscale.com/a/public-debug")
            throw IllegalStateException("https://login.tailscale.com/a/public-failure")
        }
        startTailnetService(service, prepared)
        awaitCondition("Tailnet failed startup is retired") { AuroraState.status == "error" }
        expect(android.util.Log.records.none { it.contains("login.tailscale.com") },
            "Tailnet start/debug errors must not reveal native authentication URL")
    }
    val privateClient = com.aurora.vpn.AuroraCommandClient(privateErrors = true)
    try {
        android.util.Log.records.clear()
        Libbox.beforeConnect = { throw IllegalStateException("https://login.tailscale.com/a/public-command") }
        privateClient.start()
        awaitCondition("private command connect failed") { android.util.Log.records.any { it.contains("command connect failed") } }
        expect(android.util.Log.records.none { it.contains("login.tailscale.com") },
            "Tailnet command failures do not forward raw native errors")
    } finally { privateClient.stop(); Libbox.beforeConnect = null }
    for (mode in listOf("service-throws", "listener-throws", "timeout", "stop-during-start")) {
        // A poisoned native process deliberately cannot be reset in production.
        // Each fault therefore runs in a fresh JVM, not through a test-only API.
        val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").path,
            "-cp", System.getProperty("java.class.path"), "com.aurora.vpn.test.MainKt", "tailnet-poison", mode)
            .redirectErrorStream(true).start()
        val done = child.waitFor(8, TimeUnit.SECONDS)
        if (!done) child.destroyForcibly()
        val output = child.inputStream.bufferedReader().readText()
        expect(done && child.exitValue() == 0, "isolated Tailnet $mode must retain the lease and poison admission")
        if (done && child.exitValue() != 0) print(output)
    }
}

fun tailnetPoisonTests(mode: String) {
    val root = Files.createTempDirectory("aurora-tailnet-poison-test-").toFile()
    val first = AuroraVpnService().apply { noBackupFilesDir = root }
    val next = AuroraVpnService().apply { noBackupFilesDir = root }
    val store = AuroraTailnetStore(root)
    val entered = CountDownLatch(1); val release = CountDownLatch(1)
    try {
        store.setEnabled(0, true) { true }; val prepared = store.prepareStart(1)!!
        if (mode == "stop-during-start") Libbox.beforeStart = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
        startTailnetService(first, prepared)
        if (mode == "stop-during-start") check(entered.await(3, TimeUnit.SECONDS))
        else awaitCondition("poison fixture initially connected") { AuroraState.status == "connected" }
        when (mode) {
            "stop-during-start" -> Unit
            "service-throws" -> Libbox.beforeClose = { throw IllegalStateException("public-fault") }
            "listener-throws" -> Libbox.beforeListenerClose = { throw IllegalStateException("public-fault") }
            "timeout" -> Libbox.beforeClose = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
            else -> throw IllegalArgumentException("unsupported test mode")
        }
        stopTailnetService(first)
        if (mode == "timeout" || mode == "stop-during-start") {
            check(entered.await(3, TimeUnit.SECONDS))
            Handler.fireDelayed()
            release.countDown()
        }
        awaitCondition("uncertain shutdown publishes stopped") { AuroraState.status == "disconnected" }
        expect(store.forget(prepared.nodeGeneration) { true } == "busy", "uncertain close retains node ownership until process exit")
        expect(AuroraVpnService.tailnetIsPoisoned(), "uncertain close marks the process, not just the old Service object")
        startTailnetService(next, prepared)
        // Drain the serial native queue using the main-thread status boundary.
        awaitCondition("poisoned replacement refused") { AuroraState.status in setOf("error", "connected") }
        expect(Libbox.servers.size == 1 && !AuroraVpnService.running, "a new Service object cannot start a core in a poisoned process")
    } finally {
        release.countDown(); Libbox.beforeStart = null; Libbox.beforeClose = null; Libbox.beforeListenerClose = null
        stopTailnetService(first); stopTailnetService(next)
        // The test JVM exits immediately after assertions. No production lease
        // release or reset API exists for its intentionally retained ownership.
        root.deleteRecursively()
    }
}
