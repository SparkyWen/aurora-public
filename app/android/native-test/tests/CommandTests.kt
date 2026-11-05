package com.aurora.vpn.test

import com.aurora.vpn.AuroraCommandClient
import com.aurora.vpn.AuroraState
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.StatusMessage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private fun eventually(condition: () -> Boolean): Boolean {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
    while (System.nanoTime() < deadline) {
        if (condition()) return true
        Thread.sleep(1)
    }
    return condition()
}
private fun resetCommandDoubles() {
    Libbox.clients.clear(); Libbox.beforeConnect = null; Libbox.afterConnect = null; Libbox.beforeSelect = null
    Libbox.beforeUrlTest = null
    AuroraState.clearDynamic()
}
fun commandTests() {
    unaryRetryTests()
    resetCommandDoubles()
    run {
        val client = AuroraCommandClient()
        client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        val old = Libbox.clients.last()
        old.breakTransport()
        client.selectOutbound("proxy", "via-relay")
        client.urlTest("via-relay")
        val recovered = eventually {
            Libbox.clients.size == 2 && Libbox.clients.last().selections.contains("proxy:via-relay")
        }
        expect(recovered, "two ended streams must cause one reconnect and replay the queued selection")
        if (recovered) {
            val replacement = Libbox.clients.last()
            expect(eventually { replacement.urlTests == listOf("via-relay") },
                "URL test requested during outage must run after reconnect")
            old.handler.writeStatus(StatusMessage().apply { uplink = 999L })
            old.handler.writeGroups(io.nekohasekai.libbox.OutboundGroupIterator(
                listOf(io.nekohasekai.libbox.OutboundGroup("proxy", "retired-choice"))))
            expect(AuroraState.stats["uplink"] != 999L && AuroraState.groups.single()["selected"] == "via-relay",
                "retired status/group streams cannot overwrite the replacement's readback")
            old.handler.disconnected("late retired stream")
            client.selectOutbound("proxy", "new-choice")
            expect(eventually { replacement.selections.contains("proxy:new-choice") } && Libbox.clients.size == 2,
                "a retired stream must not reconnect or strand its replacement's commands")
        }
        client.stop()
    }
    resetCommandDoubles()
    run {
        val client = AuroraCommandClient()
        client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        val old = Libbox.clients.last()
        client.stop()
        AuroraState.setStats(mapOf("uplink" to 111L))
        old.handler.writeStatus(StatusMessage().apply { uplink = 999L })
        expect(AuroraState.stats["uplink"] == 111L,
            "a stopped transport must not publish stale traffic")
    }
    resetCommandDoubles()
    run {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val completed = CountDownLatch(1)
        Libbox.beforeConnect = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
        Libbox.afterConnect = { completed.countDown() }
        val client = AuroraCommandClient()
        client.start(); check(entered.await(3, TimeUnit.SECONDS))
        val old = Libbox.clients.last()
        client.stop(); release.countDown(); check(completed.await(3, TimeUnit.SECONDS))
        expect(eventually { !old.active }, "a connect completing after stop must close its transport")
        old.handler.connected(); old.handler.disconnected("late after stop")
        expect(runCatching { client.selectOutbound("proxy", "late") }.isFailure,
            "stop must continue rejecting commands after retired callbacks")
    }
    resetCommandDoubles()
    run {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        Libbox.beforeConnect = {
            if (attempts.incrementAndGet() == 1) {
                entered.countDown(); check(release.await(3, TimeUnit.SECONDS))
                throw IllegalStateException("injected connection failure")
            }
        }
        val client = AuroraCommandClient()
        client.start(); client.start()
        check(entered.await(3, TimeUnit.SECONDS))
        client.selectOutbound("proxy", "superseded")
        client.selectOutbound("proxy", "latest")
        client.urlTest("via-relay")
        release.countDown()
        expect(eventually {
            Libbox.clients.size == 2 && Libbox.clients.last().selections == listOf("proxy:latest") &&
                Libbox.clients.last().urlTests == listOf("via-relay")
        }, "initial dial failure must preserve latest selection and pending URL test without duplicate start")
        client.stop()
    }
    resetCommandDoubles()
    run {
        val client = AuroraCommandClient(); client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        val transport = Libbox.clients.last()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        Libbox.beforeSelect = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
        client.selectOutbound("proxy", "blocked")
        check(entered.await(3, TimeUnit.SECONDS))
        val ui = java.util.concurrent.Executors.newSingleThreadExecutor()
        val stopRequest = ui.submit { client.stop() }
        val returned = try { stopRequest.get(500, TimeUnit.MILLISECONDS); true }
            catch (_: java.util.concurrent.TimeoutException) { false }
        expect(returned, "a native selector RPC must not hold the state lock needed by stop")
        release.countDown(); stopRequest.get(3, TimeUnit.SECONDS); ui.shutdown()
        expect(eventually { !transport.active }, "stop must close a transport with an in-flight selector RPC")
    }
    resetCommandDoubles()
}

private fun unaryRetryTests() {
    resetCommandDoubles()
    run {
        val selects = AtomicInteger(); val tests = AtomicInteger()
        Libbox.beforeSelect = { if (selects.incrementAndGet() == 1) error("transient selection failure") }
        Libbox.beforeUrlTest = { if (tests.incrementAndGet() == 1) error("transient URL test failure") }
        val client = AuroraCommandClient(); client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        val transport = Libbox.clients.single()
        client.selectOutbound("proxy", "recovered"); client.urlTest("auto")
        expect(eventually {
            // Stream health does not reconnect a failed unary RPC.
            transport.handler.writeStatus(StatusMessage())
            transport.selections == listOf("proxy:recovered") && transport.urlTests == listOf("auto")
        }, "selection and URL test unary failures must retry while streams stay healthy")
        expect(selects.get() == 2 && tests.get() == 2 && Libbox.clients.size == 1,
            "transient unary failures must recover once on the existing transport")
        client.stop()
    }
    resetCommandDoubles()
    run {
        val selects = AtomicInteger(); val tests = AtomicInteger()
        Libbox.beforeSelect = { selects.incrementAndGet(); error("persistent selection failure") }
        Libbox.beforeUrlTest = { tests.incrementAndGet(); error("persistent URL test failure") }
        val client = AuroraCommandClient(); client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        val transport = Libbox.clients.single()
        client.selectOutbound("proxy", "exhausted"); client.urlTest("auto")
        expect(eventually { selects.get() == 3 && tests.get() == 3 },
            "each unary request must receive its initial attempt and two bounded retries")
        // A healthy stream and a later transport must not resurrect exhausted requests.
        transport.handler.writeStatus(StatusMessage()); transport.breakTransport()
        check(eventually { Libbox.clients.size == 2 && Libbox.clients.last().active })
        Thread.sleep(800)
        expect(selects.get() == 3 && tests.get() == 3,
            "exhausted selection and URL test requests must stop retrying across reconnect")
        Libbox.beforeSelect = null; Libbox.beforeUrlTest = null
        client.selectOutbound("proxy", "fresh"); client.urlTest("auto")
        expect(eventually {
            Libbox.clients.last().selections == listOf("proxy:fresh") && Libbox.clients.last().urlTests == listOf("auto")
        }, "new user requests must remain usable after an older request exhausts its budget")
        client.stop()
    }
    for (isSelection in listOf(true, false)) {
        resetCommandDoubles()
        val attempts = AtomicInteger(); val failed = CountDownLatch(1)
        val hook: (io.nekohasekai.libbox.CommandClient) -> Unit = {
            attempts.incrementAndGet(); failed.countDown(); error("failure before stop")
        }
        if (isSelection) Libbox.beforeSelect = hook else Libbox.beforeUrlTest = hook
        val client = AuroraCommandClient(); client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        if (isSelection) client.selectOutbound("proxy", "stopped") else client.urlTest("auto")
        check(failed.await(2, TimeUnit.SECONDS)); client.stop()
        Thread.sleep(800)
        expect(attempts.get() == 1 && Libbox.clients.size == 1,
            "stop must cancel delayed ${if (isSelection) "selection" else "URL test"} retries")
    }
    for ((isSelection, afterFailure) in listOf(true to false, false to false, true to true, false to true)) {
        resetCommandDoubles()
        val attempts = AtomicInteger(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val hook: (io.nekohasekai.libbox.CommandClient) -> Unit = {
            if (attempts.incrementAndGet() == 1) {
                entered.countDown(); check(release.await(2, TimeUnit.SECONDS))
                error("superseded request failed")
            }
        }
        if (isSelection) Libbox.beforeSelect = hook else Libbox.beforeUrlTest = hook
        val client = AuroraCommandClient(); client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        val transport = Libbox.clients.single()
        if (isSelection) client.selectOutbound("proxy", "old") else client.urlTest("auto")
        check(entered.await(2, TimeUnit.SECONDS))
        if (afterFailure) { release.countDown(); Thread.sleep(100) }
        if (isSelection) client.selectOutbound("proxy", "latest") else client.urlTest("auto")
        release.countDown()
        expect(eventually {
            if (isSelection) transport.selections == listOf("proxy:latest") else transport.urlTests == listOf("auto")
        }, "a new request revision must survive its predecessor's ${if (afterFailure) "queued retry" else "late unary failure"}")
        Thread.sleep(800)
        expect(attempts.get() == 2,
            "superseded ${if (isSelection) "selection" else "URL test"} retries must never replay")
        client.stop()
    }
    resetCommandDoubles()
    run {
        val selects = AtomicInteger(); val tests = AtomicInteger()
        Libbox.beforeSelect = { if (selects.incrementAndGet() == 1) error("selection failure before reconnect") }
        Libbox.beforeUrlTest = { if (tests.incrementAndGet() == 1) error("URL test failure before reconnect") }
        val client = AuroraCommandClient(); client.start()
        check(eventually { Libbox.clients.lastOrNull()?.active == true })
        val old = Libbox.clients.single()
        client.selectOutbound("proxy", "old"); client.urlTest("auto")
        check(eventually { selects.get() == 1 && tests.get() == 1 })
        old.breakTransport()
        client.selectOutbound("proxy", "replacement"); client.urlTest("auto")
        expect(eventually {
            Libbox.clients.size == 2 && Libbox.clients.last().selections == listOf("proxy:replacement") &&
                Libbox.clients.last().urlTests == listOf("auto")
        }, "a new generation must run its latest requests after old unary retries were queued")
        Thread.sleep(800)
        expect(selects.get() == 2 && tests.get() == 2 && old.selections.isEmpty() && old.urlTests.isEmpty(),
            "retired generation retry tasks must not invoke RPCs or duplicate replacement requests")
        client.stop()
    }
    resetCommandDoubles()
}
