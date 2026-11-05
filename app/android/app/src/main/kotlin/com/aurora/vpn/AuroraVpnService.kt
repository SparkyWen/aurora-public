package com.aurora.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.ParcelFileDescriptor
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import java.util.UUID
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Aurora VPN service: foreground VpnService that runs the embedded sing-box core
 * (libbox v1.13.14) via the CommandServer model and bridges TUN + socket protection
 * through [AuroraTunPlatform]. Each start owns its native resources until cleanup.
 */
class AuroraVpnService : VpnService() {

    companion object {
        const val TAG = "Aurora"
        const val ACTION_START = "com.aurora.vpn.START"
        const val ACTION_STOP = "com.aurora.vpn.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_TAILNET_GENERATION = "tailnetGeneration"
        const val EXTRA_TAILNET_NODE = "tailnetNode"
        private const val NOTIF_CHANNEL = "aurora_vpn"
        private const val NOTIF_ID = 1

        // libbox setup and its command socket are process-wide. Serialize native
        // start/close even when Android replaces the Service object. Never wait
        // for this queue on the main thread: a cgo close can block indefinitely.
        private val engine = Executors.newSingleThreadExecutor { task ->
            Thread(task, "aurora-engine").apply { isDaemon = true }
        }
        private val lifecycleLock = Any()
        private var nextGeneration = 0
        private var activeSession: Session? = null
        private const val RELOAD_TIMEOUT_MS = 20_000L
        private val UUID_FORMAT = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

        private val tailnetAuth = AuroraTailnetAuth(SystemClock::elapsedRealtime)
        private var tailnetPoisoned = false
        private var tailnetMaintenance: Any? = null
        // A failed native close is not ownership release. Keep the lease and JNI
        // wrappers strongly reachable until the OS reclaims this entire process.
        private val retainedTailnetSessions = mutableListOf<Session>()

        fun tailnetIsPoisoned(): Boolean = synchronized(lifecycleLock) { tailnetPoisoned }
        fun tailnetIsIdle(): Boolean = synchronized(lifecycleLock) {
            activeSession == null && !tailnetPoisoned && tailnetMaintenance == null
        }
        // Reserve admission briefly, then do filesystem work without holding the
        // lifecycle lock. This closes stopped-check versus start races without
        // ever making Android's main thread wait for disk I/O.
        fun <T> withTailnetMaintenance(action: () -> T): T {
            val token = synchronized(lifecycleLock) {
                if (tailnetPoisoned) throw AuroraTailnetStoreFailure("invalid-state")
                if (activeSession != null || tailnetMaintenance != null) throw AuroraTailnetStoreFailure("busy")
                Any().also { tailnetMaintenance = it }
            }
            try { return action() } finally {
                synchronized(lifecycleLock) { if (tailnetMaintenance === token) tailnetMaintenance = null }
            }
        }

        // Captured on method receipt: the action contains an opaque owner/ticket,
        // never a URL. A reload using the same public UUID cannot lend it a new URL.
        class AuthenticationAction internal constructor(private val action: (() -> Boolean, (String) -> Unit) -> String) {
            fun dispatch(eligible: () -> Boolean, launch: (String) -> Unit): String = action(eligible, launch)
        }
        fun requestTailnetAuthentication(sessionId: String, node: String): AuthenticationAction = synchronized(lifecycleLock) {
            val session = activeSession
            val owner = session?.authOwner
            val token = session?.platformToken
            if (session == null || session.id != sessionId || session.tailnet?.node != node ||
                session.cancelled || session.reload != null || !running || owner == null || token == null) {
                return AuthenticationAction { _, _ -> "stale" }
            }
            val request = tailnetAuth.requestOpen(owner, true)
                ?: return AuthenticationAction { _, _ -> "unavailable" }
            AuthenticationAction { eligible, launch ->
                synchronized(lifecycleLock) {
                    if (!session.owner.isCurrentPlatform(session, token) || session.reload != null || !running) "stale"
                    else tailnetAuth.dispatchOpen(request) { url ->
                        // The check and synchronous Activity launch stay inside
                        // the owner gate. Failure consumes the ticket safely.
                        check(eligible())
                        launch(url)
                    }.wireValue
                }
            }
        }
        fun tailnetSnapshot(): Map<String, Any?>? = synchronized(lifecycleLock) {
            val session = activeSession?.takeIf { it.tailnet != null }
                ?: retainedTailnetSessions.lastOrNull() ?: return null
            val auth = session.authOwner?.let { !session.cancelled && session.reload == null &&
                tailnetAuth.authenticationRequired(it) } ?: false
            mapOf("schema" to 1, "sessionId" to session.id,
                "nodeGeneration" to session.tailnet!!.node,
                "publicStatus" to AuroraState.status,
                "tailnetStatus" to when {
                    session.closeUncertain -> "error"
                    session.cancelled -> "stopped"
                    auth -> "needsLogin"
                    !running || session.reload != null -> "starting"
                    else -> "unverified"
                }, "authAvailable" to auth)
        }

        fun sessionSnapshot(): Map<String, Any?> = synchronized(lifecycleLock) {
            val session = activeSession?.takeIf { running && !it.cancelled }
            mapOf("status" to if (session?.reload != null) "connecting" else AuroraState.status,
                "sessionId" to session?.id)
        }

        fun reloadCurrentSession(sessionId: String, result: (String) -> Unit) {
            val session = synchronized(lifecycleLock) {
                activeSession?.takeIf { running && !it.cancelled && it.id == sessionId }
            }
            if (session == null) result("unavailable")
            else session.owner.reloadSession(session, result)
        }

        @Volatile var running: Boolean = false
            private set
    }

    private data class TailnetRequest(val generation: Long, val node: String)
    private class Session(val generation: Int, val owner: AuroraVpnService, val tailnet: TailnetRequest?) {
        val id: String = UUID.randomUUID().toString()
        var config: String? = null
        var reload: Reload? = null
        @Volatile var cancelled = false
        var server: CommandServer? = null
        var client: AuroraCommandClient? = null
        var platform: AuroraTunPlatform? = null
        var fd: ParcelFileDescriptor? = null
        var prepared: AuroraTailnetStore.Prepared? = null
        var lease: AuroraTailnetStore.Lease? = null
        // Guard token/auth/close state with lifecycleLock. Native refs themselves
        // are only created and cleared by the serial engine.
        var platformToken: Any? = null
        var authOwner: AuroraTailnetAuth.Owner? = null
        var closeToken: Any? = null
        var retirementToken: Any? = null
        var retirementTimeout: Runnable? = null
        var closeUncertain = false
        // Only the serial engine queue releases native resources.
        var released = false
    }

    private class Reload(val result: (String) -> Unit) {
        var finished = false
        var timeout: Runnable? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private var ownedSession: Session? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopVpn()
            return START_NOT_STICKY
        }
        val hasTailnet = intent?.hasExtra(EXTRA_TAILNET_GENERATION) == true || intent?.hasExtra(EXTRA_TAILNET_NODE) == true
        val tailnet = if (hasTailnet) {
            val generation = intent?.getLongExtra(EXTRA_TAILNET_GENERATION, -1) ?: -1
            val node = intent?.getStringExtra(EXTRA_TAILNET_NODE)
            if (generation < 0 || node == null || !UUID_FORMAT.matches(node)) {
                rejectStart(startId); return START_NOT_STICKY
            }
            TailnetRequest(generation, node)
        } else null
        val session = synchronized(lifecycleLock) {
            if (tailnetPoisoned) { rejectStart(startId); return START_NOT_STICKY }
            if (tailnetMaintenance != null) { rejectStart(startId); return START_NOT_STICKY }
            ownedSession?.takeUnless { it.cancelled }?.let {
                startForegroundCompat(buildNotification(if (running) "Connected · Aurora" else "Connecting…"))
                return START_STICKY
            }
            // Neither another Service nor this cancelled instance may replace
            // an owner whose Tailnet lease is still closing. Wait for its actual
            // retirement; a status/cancel flag is not proof of cleanup.
            if (activeSession != null && (tailnet != null || activeSession?.tailnet != null)) {
                rejectStart(startId); return START_NOT_STICKY
            }
            Session(++nextGeneration, this, tailnet).also {
                ownedSession = it
                activeSession = it
                running = false
                startForegroundCompat(buildNotification("Connecting…"))
                AuroraState.set("connecting")
            }
        }
        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrBlank()) {
            Log.e(TAG, "no config provided in start intent")
            stopVpn(session)
            return START_NOT_STICKY
        }
        session.config = config
        engine.execute { startBox(config, session) }
        return START_STICKY
    }

    private fun isCurrent(session: Session): Boolean = synchronized(lifecycleLock) {
        activeSession === session && ownedSession === session && !session.cancelled
    }

    private fun rejectStart(startId: Int) {
        synchronized(lifecycleLock) {
            // START_NOT_STICKY alone does not satisfy startForegroundService's
            // OS deadline. End only this unowned request; never stop a live or
            // retiring session owned by this or another Service instance.
            if (ownedSession != null) return
            if (activeSession == null && tailnetMaintenance == null) {
                running = false
                AuroraState.set("error")
            }
            stopSelfResult(startId)
        }
    }

    private fun isCurrentPlatform(session: Session, token: Any): Boolean = synchronized(lifecycleLock) {
        isCurrent(session) && session.platformToken === token && !session.closeUncertain
    }

    private fun invalidatePlatform(session: Session) {
        synchronized(lifecycleLock) {
            session.platformToken = null
            session.authOwner?.let { tailnetAuth.invalidate(it) }
            session.authOwner = null
        }
    }

    private fun startBox(config: String, session: Session) {
        if (!isCurrent(session)) return
        try {
            var validated = config
            if (session.tailnet == null) {
                val endpoints = runCatching { JSONObject(config).optJSONArray("endpoints") }.getOrNull()
                if (endpoints != null && (0 until endpoints.length()).any {
                        val endpoint = endpoints.optJSONObject(it)
                        endpoint?.opt("type") == "tailscale" || endpoint?.opt("tag") == "aurora-tailnet"
                    }) throw AuroraTailnetStoreFailure("invalid-state")
            }
            session.tailnet?.let { request ->
                check(!tailnetIsPoisoned())
                val store = AuroraTailnetStore(applicationContext.noBackupFilesDir)
                val prepared = store.prepareStart(request.generation)
                    ?: throw AuroraTailnetStoreFailure("stale")
                if (prepared.nodeGeneration != request.node) throw AuroraTailnetStoreFailure("stale")
                validated = AuroraTailnetConfig.validate(config, prepared)
                session.prepared = prepared
                session.lease = store.acquireSessionLease(prepared, session.id)
                if (!isCurrent(session)) { releaseSession(session); return }
            }
            session.config = validated
            Libbox.setup(SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = filesDir.absolutePath
                tempPath = cacheDir.absolutePath
            })
            startNativeCore(session, validated)
            if (!isCurrent(session)) { releaseSession(session); return }
            val client = AuroraCommandClient(privateErrors = session.tailnet != null)
            session.client = client
            client.start()
            main.post {
                synchronized(lifecycleLock) {
                    if (!isCurrent(session)) return@post
                    running = true
                    AuroraState.commandClient = client
                    AuroraState.set("connected")
                    updateNotification("Connected · Aurora")
                    Log.i(TAG, "sing-box service started (generation=${session.generation})")
                }
            }
        } catch (error: Exception) {
            if (session.tailnet == null) Log.e(TAG, "startBox failed", error)
            else Log.e(TAG, "Tailnet start failed")
            releaseSession(session)
            main.post {
                synchronized(lifecycleLock) {
                    if (!isCurrent(session)) return@post
                    running = false
                    activeSession = null
                    ownedSession = null
                    AuroraState.clearDynamic()
                    AuroraState.set("error")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    private fun startNativeCore(session: Session, config: String) {
        val token = Any()
        val authOwner = synchronized(lifecycleLock) {
            check(isCurrent(session) && !session.closeUncertain && !tailnetPoisoned)
            session.platformToken = token
            session.tailnet?.let { tailnetAuth.beginOwner(session.id, it.node) }.also { session.authOwner = it }
        }
        val platform = AuroraTunPlatform(this, applicationContext,
            onNotification = { notification ->
                // Check generation before even reading the JNI fields. Never
                // read title/body/toString or pass any URL into Flutter/logs.
                synchronized(lifecycleLock) {
                    if (authOwner != null && isCurrentPlatform(session, token)) {
                        try {
                            if (notification.getIdentifier() == "tailscale-authentication" && notification.getTypeID() == 10) {
                                tailnetAuth.receive(authOwner, "tailscale-authentication", 10, notification.getOpenURL())
                            }
                        } catch (_: Exception) { /* fixed unavailable state; no native error text */ }
                    }
                }
            }, openTunnel = { options ->
                check(isCurrentPlatform(session, token)) { "VPN session unavailable" }
                establishTun(session, options, token)
            })
        session.platform = platform
        val handler = object : CommandServerHandler {
            override fun serviceStop() {
                main.post { if (isCurrentPlatform(session, token)) stopVpn(session) }
            }
            override fun serviceReload() {}
            override fun getSystemProxyStatus() = SystemProxyStatus().apply { available = false; enabled = false }
            override fun setSystemProxyEnabled(isEnabled: Boolean) {}
            override fun writeDebugMessage(message: String) {
                if (session.tailnet == null) Log.d(TAG, message)
            }
        }
        val server = Libbox.newCommandServer(handler, platform)
        session.server = server
        server.start()
        server.startOrReloadService(config, OverrideOptions())
    }

    /**
     * Called back by libbox via [AuroraTunPlatform.openTun]. Builds the Android TUN
     * with the addresses libbox computed plus FULL routes (0.0.0.0/0 + ::/0) so the
     * whole device is captured, then hands the fd to libbox.
     */
    fun establishTun(options: TunOptions): Int {
        val session = synchronized(lifecycleLock) { ownedSession }
            ?: throw IllegalStateException("VPN session unavailable")
        return establishTun(session, options)
    }

    private fun establishTun(session: Session, options: TunOptions, token: Any? = null): Int {
        fun eligible() = isCurrent(session) && (token == null || isCurrentPlatform(session, token))
        check(eligible()) { "VPN start cancelled" }
        val builder = Builder()
        // Match the iOS/macOS PacketTunnel clamp: honour a sane path MTU
        // (1280..1500) and otherwise fall back to the conservative 1400 the
        // contract ships. Never inherit libbox's 9000 default — jumbo frames
        // never survive a cross-border/hotel path and cause "big responses
        // fail, small ones pass" black holes.
        val requestedMtu = options.getMTU()
        val mtu = if (requestedMtu in 1280..1500) requestedMtu else 1400
        builder.setMtu(mtu)

        val v4 = options.getInet4Address()
        while (v4.hasNext()) {
            val p = v4.next()
            builder.addAddress(p.address(), p.prefix())
        }
        val v6 = options.getInet6Address()
        while (v6.hasNext()) {
            val p = v6.next()
            builder.addAddress(p.address(), p.prefix())
        }

        // Android full capture.
        builder.addRoute("0.0.0.0", 0)
        builder.addRoute("::", 0)

        val dns = try {
            options.getDNSServerAddress()?.value
        } catch (e: Exception) {
            null
        }
        builder.addDnsServer(if (!dns.isNullOrBlank()) dns else "1.1.1.1")

        builder.setSession("Aurora")
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)

        check(eligible()) { "VPN start cancelled before establishing TUN" }
        val pfd = builder.establish()
            ?: throw IllegalStateException("VpnService.Builder.establish() returned null (VPN not authorized?)")
        var previous: ParcelFileDescriptor? = null
        val accepted = synchronized(lifecycleLock) {
            if (!eligible()) false else {
                previous = session.fd
                session.fd = pfd
                true
            }
        }
        // libbox v1.13.14 OpenInterface duplicates the returned fd. This Java
        // wrapper remains ours, including when an in-place reload replaces it.
        runCatching { previous?.close() }
        if (!accepted) {
            pfd.close()
            throw IllegalStateException("VPN start cancelled while establishing TUN")
        }
        Log.i(TAG, "TUN established fd=${pfd.fd} mtu=$mtu")
        return pfd.fd
    }

    /** Reload only the live session. Never prepare or start another Service. */
    private fun reloadSession(session: Session, result: (String) -> Unit) {
        val attempt = synchronized(lifecycleLock) {
            if (!isCurrent(session) || !running || session.reload != null) null
            else Reload(result).also {
                session.reload = it
                if (session.tailnet != null) invalidatePlatform(session)
            }
        }
        if (attempt == null) { result("unavailable"); return }
        val timeout = Runnable {
            if (session.tailnet != null) {
                val pending = synchronized(lifecycleLock) { !attempt.finished && session.reload === attempt }
                if (pending) poisonTailnet(session)
            } else if (finishReload(session, attempt, "requiresReconnect")) stopVpn(session)
        }
        attempt.timeout = timeout
        main.postDelayed(timeout, RELOAD_TIMEOUT_MS)
        engine.execute {
            if (!isCurrent(session)) {
                finishReload(session, attempt, "unavailable")
                return@execute
            }
            try {
                val server = checkNotNull(session.server)
                val config = checkNotNull(session.config)
                // Retire desired command replay and telemetry before resetting
                // selector state. Dart will re-bootstrap path/lease policy.
                session.client?.stop()
                session.client = null
                synchronized(lifecycleLock) {
                    if (isCurrent(session)) AuroraState.clearDynamic()
                }
                if (session.tailnet != null) {
                    if (!closeTailnetCore(session)) return@execute
                    if (!isCurrent(session)) { releaseSession(session); return@execute }
                    val validated = AuroraTailnetConfig.validate(config, checkNotNull(session.prepared))
                    startNativeCore(session, validated)
                } else server.startOrReloadService(config, OverrideOptions())
                if (!isCurrent(session)) {
                    releaseSession(session)
                    finishReload(session, attempt, "unavailable")
                    return@execute
                }
                val client = AuroraCommandClient(privateErrors = session.tailnet != null)
                session.client = client
                client.start()
                main.post {
                    synchronized(lifecycleLock) {
                        if (isCurrent(session) && session.reload === attempt) {
                            AuroraState.commandClient = client
                            finishReload(session, attempt, "reloaded")
                        } else finishReload(session, attempt, "unavailable")
                    }
                }
            } catch (_: Exception) {
                // A failed reload may leave a half-closed core. Retire it using
                // the existing serial cleanup; never launch a replacement VPN.
                if (finishReload(session, attempt, "requiresReconnect")) stopVpn(session)
            }
        }
    }

    private fun finishReload(session: Session, attempt: Reload, value: String): Boolean {
        val outcome = synchronized(lifecycleLock) {
            if (attempt.finished) return false
            attempt.finished = true
            if (session.reload === attempt) session.reload = null
            if (!isCurrent(session)) "unavailable" else value
        }
        attempt.timeout?.let { main.removeCallbacks(it) }
        main.post { attempt.result(outcome) }
        return true
    }

    private fun stopVpn(expected: Session? = null) {
        val session = synchronized(lifecycleLock) {
            val current = ownedSession
            if (expected != null && current !== expected) return
            if (current == null) {
                if (activeSession == null) {
                    running = false
                    AuroraState.clearDynamic()
                    AuroraState.set("disconnected")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                return
            }
            if (current.cancelled) return
            invalidatePlatform(current)
            current.cancelled = true
            if (current.tailnet != null) armTailnetRetirement(current)
            current.reload?.let { finishReload(current, it, "unavailable") }
            if (activeSession === current) {
                running = false
                AuroraState.clearDynamic()
                AuroraState.set("disconnecting")
            }
            current
        }
        engine.execute {
            releaseSession(session)
            main.post {
                synchronized(lifecycleLock) {
                    if (ownedSession !== session || activeSession !== session) return@post
                    ownedSession = null
                    activeSession = null
                    AuroraState.set("disconnected")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    private fun releaseSession(session: Session) {
        if (session.released) return
        if (session.tailnet != null) {
            invalidatePlatform(session)
            if (!closeTailnetCore(session)) return
            try { session.lease?.close() } catch (_: Exception) { poisonTailnet(session); return }
            session.lease = null
            synchronized(lifecycleLock) {
                session.released = true
                session.retirementToken = null
                session.retirementTimeout?.let { main.removeCallbacks(it) }
                session.retirementTimeout = null
            }
            return
        }
        session.released = true
        runCatching { session.client?.stop() }
        runCatching { session.server?.closeService() }.onFailure { Log.w(TAG, "closeService", it) }
        runCatching { session.server?.close() }.onFailure { Log.w(TAG, "close", it) }
        runCatching { session.platform?.close() }
        runCatching { session.fd?.close() }
        session.client = null
        session.server = null
        session.platform = null
        session.fd = null
    }

    private fun armTailnetRetirement(session: Session) {
        // Start the bound when stop is requested, including time spent waiting
        // behind an in-flight Go start. A blocked engine is not a stopped core.
        val token = Any()
        val timeout = Runnable {
            synchronized(lifecycleLock) {
                if (session.retirementToken === token && !session.released) poisonTailnet(session)
            }
        }
        session.retirementToken = token
        session.retirementTimeout = timeout
        main.postDelayed(timeout, RELOAD_TIMEOUT_MS)
    }

    // Runs on the engine queue. The timeout may only retire/poison from main;
    // it never closes a lock or disposes resources still in use by native code.
    private fun closeTailnetCore(session: Session): Boolean {
        val token = synchronized(lifecycleLock) {
            if (session.closeUncertain) return false
            Any().also { session.closeToken = it }
        }
        val timeout = Runnable {
            synchronized(lifecycleLock) {
                if (session.closeToken === token) poisonTailnet(session)
            }
        }
        main.postDelayed(timeout, RELOAD_TIMEOUT_MS)
        var success = true
        try {
            try { session.client?.stop() } catch (_: Exception) { success = false }
            // Attempt listener shutdown as well, but neither error licenses
            // releasing the lease or starting a second core in this process.
            try { session.server?.closeService() } catch (_: Exception) { success = false }
            try { session.server?.close() } catch (_: Exception) { success = false }
            if (!success) { poisonTailnet(session); return false }
            if (synchronized(lifecycleLock) { session.closeUncertain }) return false
            try { session.platform?.close(); session.fd?.close() } catch (_: Exception) {
                poisonTailnet(session); return false
            }
            synchronized(lifecycleLock) {
                if (session.closeUncertain) return false
                session.closeToken = null
            }
            session.client = null; session.server = null; session.platform = null; session.fd = null
            return true
        } finally { main.removeCallbacks(timeout) }
    }

    private fun poisonTailnet(session: Session) {
        synchronized(lifecycleLock) {
            if (session.closeUncertain) return
            tailnetPoisoned = true
            session.closeUncertain = true
            session.retirementToken = null
            session.retirementTimeout?.let { main.removeCallbacks(it) }
            session.retirementTimeout = null
            retainedTailnetSessions.add(session)
            session.reload?.let { finishReload(session, it, "requiresReconnect") }
            invalidatePlatform(session)
            session.cancelled = true
            if (activeSession === session) {
                running = false
                AuroraState.clearDynamic()
            }
        }
        // An indefinitely blocked native thread cannot complete a stop event.
        // Publish retirement separately; the process/lease remains poisoned.
        main.post {
            synchronized(lifecycleLock) {
                if (activeSession !== session || ownedSession !== session) return@post
                activeSession = null; ownedSession = null
                AuroraState.set("disconnected")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    override fun onRevoke() {
        stopVpn()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    // ---- foreground notification ----

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun buildNotification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(NOTIF_CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(NOTIF_CHANNEL, "Aurora VPN", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, NOTIF_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Aurora")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(text))
    }
}
