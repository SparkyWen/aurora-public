package com.aurora.vpn

import java.net.URI
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction

class AuroraTailnetAuthFailure : Exception("invalid-arguments")

// Native memory only. Inject SystemClock.elapsedRealtime (includes deep sleep),
// not wall time or System.nanoTime. No URL is exposed by Owner/OpenRequest or
// by the snapshot boolean; only the final native launch sink receives it.
class AuroraTailnetAuth(private val elapsedRealtimeMillis: () -> Long) {
    class Owner internal constructor(val sessionId: String, val nodeGeneration: String)
    class OpenRequest internal constructor(internal val owner: Owner)
    enum class OpenResult(val wireValue: String) { OPENED("opened"), UNAVAILABLE("unavailable"), STALE("stale") }

    private class Pending(val url: String, val receivedAt: Long)
    private val lock = Any()
    private var current: Owner? = null
    private var pending: Pending? = null
    private var queued: OpenRequest? = null

    fun beginOwner(sessionId: String, nodeGeneration: String): Owner = synchronized(lock) {
        val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        if (!uuid.matches(sessionId) || !uuid.matches(nodeGeneration)) throw AuroraTailnetAuthFailure()
        clear()
        // Each native platform/reload must obtain a new token, even for the
        // same session UUID. Late old-platform callbacks cannot regain ownership.
        Owner(sessionId, nodeGeneration).also { current = it }
    }

    fun receive(owner: Owner, identifier: String, typeID: Int, rawURL: String): Boolean = synchronized(lock) {
        if (current !== owner || identifier != "tailscale-authentication" || typeID != 10 || !validURL(rawURL)) {
            return@synchronized false
        }
        val now = now() ?: return@synchronized false
        pending = Pending(rawURL, now)
        queued = null
        true
    }

    fun authenticationRequired(owner: Owner): Boolean = synchronized(lock) { live(owner) != null }

    fun requestOpen(owner: Owner, userGesture: Boolean): OpenRequest? = synchronized(lock) {
        if (!userGesture || live(owner) == null || queued != null) return@synchronized null
        OpenRequest(owner).also { queued = it }
    }

    // Call this on the eventual native UI dispatch, not when posting its task.
    // The synchronous sink must only make the nonblocking launch call; never
    // queue work, wait for another thread, perform I/O, or return the URL to Dart.
    // Keeping it in this short lock orders invalidate versus the actual call.
    fun dispatchOpen(request: OpenRequest, launch: (String) -> Unit): OpenResult = synchronized(lock) {
        if (current !== request.owner) return@synchronized OpenResult.STALE
        if (queued !== request) return@synchronized OpenResult.UNAVAILABLE
        val value = live(request.owner) ?: return@synchronized OpenResult.UNAVAILABLE
        clear()
        try {
            launch(value.url)
            OpenResult.OPENED
        } catch (_: Exception) {
            // A failing sink stays consumed. Never forward its message/cause,
            // which can contain the authentication URL, or retry automatically.
            OpenResult.UNAVAILABLE
        }
    }

    // Stop, reload, forget and terminal failure call this before retiring their
    // platform. A late old-owner cleanup must not affect the current platform.
    fun invalidate(owner: Owner) = synchronized(lock) {
        if (current === owner) { clear(); current = null }
    }

    private fun clear() { pending = null; queued = null }

    private fun now(): Long? = try { elapsedRealtimeMillis().takeIf { it >= 0 } } catch (_: Exception) { null }

    private fun live(owner: Owner): Pending? {
        if (current !== owner) return null
        val value = pending ?: return null
        val now = now()
        if (now == null || now < value.receivedAt || now - value.receivedAt >= 300_000L) {
            clear()
            return null
        }
        return value
    }

    private fun validURL(value: String): Boolean {
        if (value.length > 4096 || value.any { it.code in 0..31 || it.code in 127..159 }) return false
        return try {
            val encoder = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            if (encoder.encode(CharBuffer.wrap(value)).remaining() > 4096) return false
            val uri = URI(value)
            uri.scheme == "https" && uri.host == "login.tailscale.com" && uri.rawUserInfo == null &&
                (uri.rawAuthority == "login.tailscale.com" || uri.rawAuthority == "login.tailscale.com:443")
        } catch (_: Exception) { false }
    }
}
