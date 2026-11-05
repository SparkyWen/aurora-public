package com.aurora.vpn.test

import android.content.Intent
import android.net.VpnService
import android.os.Handler
import com.aurora.vpn.AuroraState
import com.aurora.vpn.AuroraVpnService
import io.nekohasekai.libbox.Libbox
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors

fun awaitCondition(message: String, condition: () -> Boolean) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
    while (System.nanoTime() < deadline) {
        Handler.drain()
        if (condition()) return
        Thread.sleep(1)
    }
    throw AssertionError("timed out: $message")
}
private fun start(service: AuroraVpnService, config: String) = service.onStartCommand(
    Intent().apply { action = AuroraVpnService.ACTION_START; putExtra(AuroraVpnService.EXTRA_CONFIG, config) }, 0, 1)
private fun stop(service: AuroraVpnService) = service.onStartCommand(
    Intent().apply { action = AuroraVpnService.ACTION_STOP }, 0, 2)
private fun resetServiceDoubles() {
    Libbox.beforeStart = null; Libbox.afterStart = null; Libbox.beforeClose = null
    Libbox.servers.clear(); Libbox.clients.clear(); VpnService.established.clear()
    AuroraState.set("disconnected"); AuroraState.clearDynamic(); Handler.drain()
}
fun serviceTests(includeReplacement: Boolean = true) {
    val originalSdk = android.os.Build.VERSION.SDK_INT
    try {
        for (sdk in listOf(24, 25, 26, originalSdk).distinct()) {
            resetServiceDoubles()
            android.os.Build.VERSION.SDK_INT = sdk
            val service = AuroraVpnService()
            try {
                val failure = runCatching { start(service, "notification-api-$sdk") }.exceptionOrNull()
                expect(failure == null, "API $sdk foreground startup must use an available notification API, got $failure")
                if (failure == null) {
                    awaitCondition("API $sdk notification startup") { AuroraState.status == "connected" }
                }
            } finally {
                stop(service)
                awaitCondition("API $sdk notification cleanup") { AuroraState.status == "disconnected" }
            }
        }
    } finally {
        android.os.Build.VERSION.SDK_INT = originalSdk
    }

    resetServiceDoubles()
    run {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        Libbox.beforeStart = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
        val service = AuroraVpnService()
        start(service, "destroy-during-start")
        check(entered.await(3, TimeUnit.SECONDS))
        service.onDestroy(); release.countDown()
        awaitCondition("destroyed startup finishes") {
            Libbox.servers.first().closed || AuroraState.status == "connected"
        }
        expect(!AuroraVpnService.running && AuroraState.status != "connected",
            "onDestroy during startup must prevent a late connected commit")
        stop(service)
        awaitCondition("destroyed session teardown") { Libbox.servers.all { it.closed } }
        awaitCondition("destroyed state settles") { AuroraState.status == "disconnected" }
    }
    resetServiceDoubles()
    run {
        val service = AuroraVpnService()
        start(service, "old")
        awaitCondition("first session connected") { AuroraState.status == "connected" }
        val old = Libbox.servers.single()
        stop(service)
        awaitCondition("first session stopped") { AuroraState.status == "disconnected" }
        start(service, "new")
        awaitCondition("replacement connected") { AuroraState.status == "connected" }
        val current = Libbox.servers.last()
        old.handler.serviceStop()
        Handler.drain()
        expect(AuroraState.status == "connected" && !current.closed,
            "a retired core's serviceStop must not stop its replacement")
        stop(service)
        awaitCondition("replacement stopped") { current.closed }
        awaitCondition("replacement state settles") { AuroraState.status == "disconnected" }
    }
    resetServiceDoubles()
    run {
        val service = AuroraVpnService()
        start(service, "blocking-close")
        awaitCondition("blocking-close session connected") { AuroraState.status == "connected" }
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        Libbox.beforeClose = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
        val ui = Executors.newSingleThreadExecutor()
        val stopRequest = ui.submit { stop(service) }
        check(entered.await(3, TimeUnit.SECONDS))
        val returned = try {
            stopRequest.get(500, TimeUnit.MILLISECONDS)
            true
        } catch (_: java.util.concurrent.TimeoutException) { false }
        expect(returned, "stop request must return while native closeService is blocked")
        release.countDown(); stopRequest.get(3, TimeUnit.SECONDS); ui.shutdown()
        awaitCondition("blocking close released") { AuroraState.status == "disconnected" }
    }
    resetServiceDoubles()
    if (!includeReplacement) return
    for (failOld in listOf(false, true)) {
        val service = AuroraVpnService()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val transitions = mutableListOf<String>()
        val listener: (String) -> Unit = { transitions.add(it) }
        AuroraState.addListener(listener)
        if (failOld) {
            Libbox.beforeStart = { server ->
                if (server.config == "old-pending") {
                    entered.countDown(); check(release.await(3, TimeUnit.SECONDS))
                    throw IllegalStateException("injected retired startup failure")
                }
            }
        } else {
            Libbox.afterStart = { server ->
                if (server.config == "old-pending") {
                    entered.countDown(); check(release.await(3, TimeUnit.SECONDS))
                }
            }
        }
        start(service, "old-pending")
        check(entered.await(3, TimeUnit.SECONDS))
        stop(service); start(service, "replacement")
        release.countDown()
        awaitCondition("replacement after retired startup") {
            Libbox.servers.any { it.config == "replacement" } && AuroraState.status == "connected"
        }
        val current = Libbox.servers.last { it.config == "replacement" }
        expect(!current.closed && VpnService.established.single { it.fd == current.fd }.closed.not(),
            "retired startup cleanup must leave the replacement TUN open (error=$failOld)")
        expect(transitions.count { it == "connected" } == 1 && "error" !in transitions,
            "retired startup cannot publish connected/error over its replacement (error=$failOld)")
        stop(service)
        awaitCondition("retired startup scenario settled") { AuroraState.status == "disconnected" }
        AuroraState.removeListener(listener)
        resetServiceDoubles()
    }
}
