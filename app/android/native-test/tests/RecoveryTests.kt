package com.aurora.vpn.test

import android.content.Intent
import android.net.VpnService
import com.aurora.vpn.AuroraState
import com.aurora.vpn.AuroraVpnService
import io.nekohasekai.libbox.Libbox

fun recoveryTests() {
    Libbox.beforeStart = null; Libbox.afterStart = null; Libbox.beforeClose = null
    Libbox.servers.clear(); VpnService.established.clear()
    val service = AuroraVpnService()
    service.onStartCommand(Intent().apply {
        action = AuroraVpnService.ACTION_START
        putExtra(AuroraVpnService.EXTRA_CONFIG, "existing-config")
    }, 0, 1)
    awaitCondition("recovery source connected") { AuroraState.status == "connected" }
    val server = Libbox.servers.single()
    val oldFd = VpnService.established.single()
    val id = AuroraVpnService.sessionSnapshot()["sessionId"] as? String
    expect(!id.isNullOrEmpty(), "connected native session must expose an opaque recovery identity")
    var result: String? = null
    AuroraVpnService.reloadCurrentSession(id ?: "missing") { result = it }
    awaitCondition("reload returns") { result != null }
    expect(result == "reloaded", "existing session reload must succeed without a replacement service")
    expect(server.startCalls == 2 && Libbox.servers.size == 1,
        "reload must reuse exactly the existing CommandServer and config")
    expect(oldFd.closed, "reload must release the superseded Java-owned TUN fd")
    expect(AuroraVpnService.sessionSnapshot()["sessionId"] == id,
        "reload must preserve the native session identity")
    service.onRevoke()
    var revoked: String? = null
    AuroraVpnService.reloadCurrentSession(id ?: "missing") { revoked = it }
    awaitCondition("revocation rejects queued recovery") { revoked != null }
    expect(revoked == "unavailable", "onRevoke must invalidate recovery before cleanup finishes")
    awaitCondition("recovery source retired") { AuroraState.status == "disconnected" }
    expect(AuroraVpnService.sessionSnapshot()["sessionId"] == null,
        "retired service must not expose a reusable identity")
}

fun recoveryRaceTests() {
    for (failure in listOf("revoke", "timeout", "core-error")) {
        Libbox.beforeStart = null; Libbox.afterStart = null; Libbox.beforeClose = null
        Libbox.servers.clear(); VpnService.established.clear()
        val service = AuroraVpnService()
        fun start(config: String) = service.onStartCommand(Intent().apply {
            action = AuroraVpnService.ACTION_START
            putExtra(AuroraVpnService.EXTRA_CONFIG, config)
        }, 0, 1)
        start("original")
        awaitCondition("$failure source connected") { AuroraState.status == "connected" }
        val server = Libbox.servers.single()
        val id = AuroraVpnService.sessionSnapshot()["sessionId"] as String
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        Libbox.beforeStart = { current ->
            if (current === server && current.startCalls > 1) {
                entered.countDown()
                check(release.await(3, java.util.concurrent.TimeUnit.SECONDS))
                if (failure == "core-error") throw IllegalStateException("injected core reload error")
            }
        }
        val results = mutableListOf<String>()
        AuroraVpnService.reloadCurrentSession(id) { results.add(it) }
        check(entered.await(3, java.util.concurrent.TimeUnit.SECONDS))
        expect(AuroraVpnService.sessionSnapshot()["status"] == "connecting" &&
            AuroraVpnService.sessionSnapshot()["sessionId"] == id,
            "$failure: busy snapshot must preserve identity without advertising ready")
        var duplicate: String? = null
        AuroraVpnService.reloadCurrentSession(id) { duplicate = it }
        expect(duplicate == "unavailable", "$failure: concurrent reload must not queue another core")
        when (failure) {
            "revoke" -> service.onRevoke()
            "timeout" -> android.os.Handler.fireDelayed()
        }
        if (failure != "core-error") {
            awaitCondition("$failure bounded response") { results.isNotEmpty() }
            expect(results.single() == if (failure == "revoke") "unavailable" else "requiresReconnect",
                "$failure: bounded result must reflect external cancellation or failure")
            expect(AuroraVpnService.sessionSnapshot()["sessionId"] == null,
                "$failure: no usable session token survives cancellation")
        }
        release.countDown()
        awaitCondition("$failure retires old session") { AuroraState.status == "disconnected" }
        if (failure == "core-error") {
            expect(results.single() == "requiresReconnect", "core error requires an explicit user reconnect")
        }
        expect(results.size == 1, "$failure: late native return must not complete twice")
        expect(VpnService.established.size == 1 && VpnService.established.single().closed,
            "$failure: revoked/failed reload must never establish a late TUN")
        start("manual-replacement")
        awaitCondition("$failure explicit reconnect") { AuroraState.status == "connected" }
        val newId = AuroraVpnService.sessionSnapshot()["sessionId"] as String
        expect(id != newId, "$failure: explicit replacement owns a fresh UUID")
        var obsolete: String? = null
        AuroraVpnService.reloadCurrentSession(id) { obsolete = it }
        expect(obsolete == "unavailable", "$failure: old identity cannot reload a replacement")
        expect(Libbox.servers.size == 2 && Libbox.servers.last().startCalls == 1,
            "$failure: recovery never automatically starts a new service")
        service.onRevoke()
        awaitCondition("$failure cleanup") { AuroraState.status == "disconnected" }
    }
    Libbox.beforeStart = null; Libbox.afterStart = null; Libbox.beforeClose = null
}
