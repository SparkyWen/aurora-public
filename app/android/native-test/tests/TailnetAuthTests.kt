package com.aurora.vpn.test

import com.aurora.vpn.AuroraTailnetAuth
import com.aurora.vpn.AuroraTailnetAuthFailure
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private const val AUTH_SESSION = "12345678-1234-1234-1234-123456789ABC"
private const val AUTH_NODE = "ABCDEF12-1234-1234-1234-ABCDEF123456"
private const val AUTH_URL = "https://login.tailscale.com/a/public-fixture"
private const val AUTH_ID = "tailscale-authentication"

fun tailnetAuthTests() {
    fun case(name: String, body: () -> Unit) {
        try { body() } catch (error: Throwable) { expect(false, "$name: ${error.javaClass.simpleName}") }
    }
    class Fixture {
        var now = 1000L
        val holder = AuroraTailnetAuth { now }
        val owner = holder.beginOwner(AUTH_SESSION, AUTH_NODE)
        fun offer(url: String = AUTH_URL) = holder.receive(owner, AUTH_ID, 10, url)
        fun open(): Pair<AuroraTailnetAuth.OpenResult?, List<String>> {
            val seen = mutableListOf<String>()
            val request = holder.requestOpen(owner, true)
            val result = request?.let { holder.dispatchOpen(it) { url -> seen.add(url) } }
            return result to seen
        }
    }
    for (url in listOf(AUTH_URL, "https://login.tailscale.com:443/a", "https://login.tailscale.com/a?next=%2F")) {
        case("valid HTTPS authentication") {
            val f = Fixture()
            expect(f.offer(url), "valid URL is accepted")
            expect(f.holder.authenticationRequired(f.owner), "accepted notification exposes only auth-required state")
            val (result, seen) = f.open()
            expect(result == AuroraTailnetAuth.OpenResult.OPENED && seen == listOf(url), "one explicit gesture launches the original native URL")
            expect(f.open().second.isEmpty() && !f.holder.authenticationRequired(f.owner), "consumed URL cannot launch twice")
        }
    }
    val rejectedURLs = listOf(
        "http://login.tailscale.com/a", "https://login.tailscale.com.evil/a",
        "https://evil.example/login.tailscale.com/a", "https://user@login.tailscale.com/a",
        "https://login.tailscale.com:444/a", "https://login.tailscale.com:/a",
        "https://login.tailscale.com./a", "https://LOGIN.TAILSCALE.COM/a",
        "HTTPS://login.tailscale.com/a", "https://login%2Etailscale.com/a",
        "https://login.tailscale.com\\@evil.example/a", " https://login.tailscale.com/a",
        "https://login.tailscale.com/a\n", "https://login.tailscale.com/a\u0000",
        "https://login.tailscale.com/a\u007f", "https://login.tailscale.com/a\u0085",
        "https://login.tailscale.com/\ud800", "https://login.tailscale.com/" + "a".repeat(4096))
    for ((index, url) in rejectedURLs.withIndex()) {
        case("URL rejection $index") {
            val f = Fixture()
            expect(!f.offer(url) && !f.holder.authenticationRequired(f.owner) && f.open().second.isEmpty(),
                "invalid URL $index never enters the holder or launch sink")
        }
    }
    case("UTF-8 limit counts bytes") {
        val f = Fixture(); val prefix = "https://login.tailscale.com/"
        val boundary = prefix + "é".repeat(2034)
        expect(boundary.toByteArray(Charsets.UTF_8).size == 4096, "fixture is the exact UTF-8 byte boundary")
        expect(f.offer(boundary), "4096 UTF-8 bytes allowed")
        expect(!f.offer(boundary + "é"), "4098 UTF-8 bytes refused")
        expect(f.open().second == listOf(boundary), "invalid replacement preserves the valid pending notification")
    }
    case("notification category is exact") {
        val f = Fixture()
        for ((identifier, type) in listOf("other" to 10, AUTH_ID to 9, AUTH_ID to 11)) {
            expect(!f.holder.receive(f.owner, identifier, type, AUTH_URL), "unrelated notification refused")
        }
        expect(!f.holder.authenticationRequired(f.owner), "unrelated messages create no auth state")
    }
    case("UUID ownership is strict and case preserving") {
        val f = Fixture()
        expect(f.owner.sessionId == AUTH_SESSION && f.owner.nodeGeneration == AUTH_NODE, "native owner preserves UUID case")
        for (bad in listOf("", "1-1-1-1-1", AUTH_SESSION + "\n", "G" + AUTH_SESSION.drop(1))) {
            val failed = try { f.holder.beginOwner(bad, AUTH_NODE); false }
                catch (e: AuroraTailnetAuthFailure) { e.message == "invalid-arguments" }
            expect(failed, "malformed session has one safe fixed error")
            val badNode = try { f.holder.beginOwner(AUTH_SESSION, bad); false }
                catch (e: AuroraTailnetAuthFailure) { e.message == "invalid-arguments" }
            expect(badNode, "malformed node has one safe fixed error")
        }
        expect(f.offer(), "invalid owner input does not revoke the current valid owner")
    }
    case("no implicit user gesture") {
        val f = Fixture(); f.offer()
        expect(f.holder.requestOpen(f.owner, false) == null, "background notification cannot consume a URL")
        expect(f.open().first == AuroraTailnetAuth.OpenResult.OPENED, "later explicit gesture still works")
    }
    case("one pending dispatch at a time") {
        val f = Fixture(); f.offer()
        val request = f.holder.requestOpen(f.owner, true)!!
        expect(f.holder.requestOpen(f.owner, true) == null, "queued request consumes the pending gesture once")
        var calls = 0
        expect(f.holder.dispatchOpen(request) { calls++ } == AuroraTailnetAuth.OpenResult.OPENED, "queued native dispatch opens")
        expect(f.holder.dispatchOpen(request) { calls++ } == AuroraTailnetAuth.OpenResult.UNAVAILABLE && calls == 1,
            "replayed dispatch ticket cannot open twice")
    }
    case("TTL includes time waiting for native dispatch") {
        val f = Fixture(); f.offer(); f.now += 299999
        val ticket = f.holder.requestOpen(f.owner, true)!!; f.now++
        var calls = 0
        expect(f.holder.dispatchOpen(ticket) { calls++ } == AuroraTailnetAuth.OpenResult.UNAVAILABLE && calls == 0,
            "age exactly five minutes is expired even after an earlier user gesture")
        expect(!f.holder.authenticationRequired(f.owner), "expired secret no longer advertises auth state")
    }
    case("TTL before boundary") {
        val f = Fixture(); f.offer(); f.now += 299999
        expect(f.open().first == AuroraTailnetAuth.OpenResult.OPENED, "one millisecond before expiry remains usable")
    }
    case("expired pending URL cannot be requested") {
        val f = Fixture(); f.offer(); f.now += 300000
        expect(f.holder.requestOpen(f.owner, true) == null, "expired pending notification cannot queue")
    }
    for (badTime in listOf(-1L, 999L, Long.MAX_VALUE)) {
        case("invalid or overflowing clock age") {
            val f = Fixture(); f.offer(); f.now = badTime
            expect(!f.holder.authenticationRequired(f.owner) && f.open().second.isEmpty(), "bad or long elapsed time fails closed")
        }
    }
    for (lifecycle in listOf("stop", "reload", "forget")) {
        case("$lifecycle invalidates queued dispatch") {
            val f = Fixture(); f.offer(); val request = f.holder.requestOpen(f.owner, true)!!
            f.holder.invalidate(f.owner)
            var calls = 0
            expect(f.holder.dispatchOpen(request) { calls++ } == AuroraTailnetAuth.OpenResult.STALE && calls == 0,
                "$lifecycle rejects delayed browser dispatch")
            expect(!f.offer() && !f.holder.authenticationRequired(f.owner), "$lifecycle rejects old platform callbacks")
        }
    }
    case("reload with the same UUID still changes owner generation") {
        val f = Fixture(); f.offer(); val oldRequest = f.holder.requestOpen(f.owner, true)!!
        val newer = f.holder.beginOwner(AUTH_SESSION, AUTH_NODE)
        expect(!f.offer(), "same-UUID reload rejects old owner token")
        expect(f.holder.receive(newer, AUTH_ID, 10, AUTH_URL), "new owner can receive its own notification")
        f.holder.invalidate(f.owner)
        expect(f.holder.dispatchOpen(oldRequest) {} == AuroraTailnetAuth.OpenResult.STALE, "old request cannot launch after replacement")
        expect(f.holder.requestOpen(newer, true) != null, "late old stop does not revoke the new owner")
    }
    case("new node invalidates old request") {
        val f = Fixture(); f.offer(); val old = f.holder.requestOpen(f.owner, true)!!
        f.holder.beginOwner(AUTH_SESSION, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        expect(f.holder.dispatchOpen(old) {} == AuroraTailnetAuth.OpenResult.STALE, "different node cancels old authentication")
    }
    case("replacement notification revokes queued old URL") {
        val f = Fixture(); f.offer(); val old = f.holder.requestOpen(f.owner, true)!!
        f.offer("https://login.tailscale.com/a/new-public-fixture")
        expect(f.holder.dispatchOpen(old) {} == AuroraTailnetAuth.OpenResult.UNAVAILABLE, "old notification ticket cannot launch the replacement URL")
        expect(f.open().second == listOf("https://login.tailscale.com/a/new-public-fixture"), "new URL requires a fresh gesture")
    }
    case("sink failure remains consumed and safe") {
        val f = Fixture(); f.offer(); val request = f.holder.requestOpen(f.owner, true)!!
        val result = f.holder.dispatchOpen(request) { throw IllegalStateException(AUTH_URL) }
        expect(result == AuroraTailnetAuth.OpenResult.UNAVAILABLE, "browser rejection has no raw exception or URL")
        expect(f.holder.dispatchOpen(request) {} == AuroraTailnetAuth.OpenResult.UNAVAILABLE, "failed browser call has no automatic retry")
        expect(!request.toString().contains("tailscale"), "opaque ticket does not render the auth URL")
    }
    case("different holder cannot dispatch another holder's ticket") {
        val f = Fixture(); f.offer(); val ticket = f.holder.requestOpen(f.owner, true)!!
        val other = Fixture()
        expect(other.holder.dispatchOpen(ticket) {} == AuroraTailnetAuth.OpenResult.STALE, "cross-holder ticket is unavailable")
        expect(f.holder.dispatchOpen(ticket) {} == AuroraTailnetAuth.OpenResult.OPENED, "foreign attempt does not consume the original ticket")
    }
    case("concurrent gestures launch once") {
        val f = Fixture(); f.offer(); val start = CountDownLatch(1); val finished = CountDownLatch(2)
        val calls = AtomicInteger(); val errors = AtomicInteger()
        repeat(2) {
            Thread {
                try {
                    start.await()
                    f.holder.requestOpen(f.owner, true)?.let { ticket -> f.holder.dispatchOpen(ticket) { calls.incrementAndGet() } }
                } catch (_: Throwable) { errors.incrementAndGet() } finally { finished.countDown() }
            }.start()
        }
        start.countDown()
        expect(finished.await(3, TimeUnit.SECONDS) && errors.get() == 0 && calls.get() == 1,
            "two actual threads consume one auth notification exactly once")
    }
    case("clock failure cannot expose an injected error") {
        val holder = AuroraTailnetAuth { throw IllegalStateException(AUTH_URL) }
        val owner = holder.beginOwner(AUTH_SESSION, AUTH_NODE)
        expect(!holder.receive(owner, AUTH_ID, 10, AUTH_URL), "clock failure rejects without exposing exception text")
    }
}
