package com.aurora.vpn

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.nekohasekai.libbox.Libbox
import java.io.File
import java.util.concurrent.Executors

// Independent native channel. No response exposes an authentication URL. The
// Activity owns the synchronous browser sink and its foreground/lifetime check.
class AuroraTailnetChannel(
    private val directory: File,
    private val currentActivity: () -> Boolean,
    private val foreground: () -> Boolean,
    private val startService: (String, Long, String) -> Unit,
    private val launch: (String) -> Unit,
    private val work: (() -> Unit) -> Unit = { task -> worker.execute(task) },
    private val post: (() -> Unit) -> Unit = { task -> Handler(Looper.getMainLooper()).post(task) },
    private val clock: () -> Long = SystemClock::elapsedRealtime,
) {
    interface Result { fun success(value: Any?); fun error(code: String) }
    companion object {
        private val worker = Executors.newSingleThreadExecutor { task ->
            Thread(task, "aurora-tailnet-settings").apply { isDaemon = true }
        }
        private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        // Constructor-only libbox validation. No Setup/Start or native store API
        // is called, so checking build-tag support cannot create a node/login.
        private const val CAPABILITY_CONFIG = """{"log":{"disabled":true},"endpoints":[{"type":"tailscale","tag":"aurora-tailnet","state_directory":"/aurora-capability-no-start","system_interface":false,"ephemeral":false,"accept_routes":false,"advertise_routes":[],"advertise_exit_node":false}]}"""
        private val knownErrors = setOf("unsupported", "busy", "stale", "storage", "invalid-state")
    }
    private val lock = Any()
    private var inFlight: Any? = null

    fun handle(method: String, arguments: Any?, result: Result) {
        val received = try { clock() } catch (_: Exception) { result.error("stale"); return }
        val args = try { arguments(method, arguments) } catch (error: AuroraTailnetStoreFailure) {
            result.error(error.code); return
        }
        val token = synchronized(lock) {
            if (inFlight != null) { result.error("busy"); return }
            Any().also { inFlight = it }
        }
        fun live(): Boolean = try {
            val now = clock()
            currentActivity() && received >= 0 && now >= received && now - received < 4_000
        } catch (_: Exception) { false }
        fun finish(value: Any?, error: String? = null, checkDeadline: Boolean = true) {
            synchronized(lock) {
                if (inFlight !== token) return
                inFlight = null
            }
            if (checkDeadline && !live()) result.error("stale")
            else if (error != null) result.error(error)
            else result.success(value)
        }
        fun fail(error: Exception): String = (error as? AuroraTailnetStoreFailure)?.code
            ?.takeIf { it in knownErrors } ?: "storage"
        try {
            if (!live()) { finish(null, "stale"); return }
            if (method == "openAuthentication") {
                // Capture the original platform Owner now, before posting the
                // eventual UI launch. Dart's own timeout does not cancel native.
                val action = AuroraVpnService.requestTailnetAuthentication(args["sessionId"] as String,
                    args["nodeGeneration"] as String)
                post {
                    val value = action.dispatch({ live() && foreground() }, launch)
                    finish(value, checkDeadline = false)
                }
                return
            }
            if (method == "start") {
                if (!foreground() || !AuroraVpnService.tailnetIsIdle()) { finish(null, "busy"); return }
                startService(args["config"] as String, generation(args["settingsGeneration"]), args["nodeGeneration"] as String)
                finish(null) // dispatched, not a readiness/connected assertion
                return
            }
            work {
                var value: Any? = null; var error: String? = null
                try {
                    if (!live()) throw AuroraTailnetStoreFailure("stale")
                    if (method == "capability") {
                        value = try { Libbox.checkConfig(CAPABILITY_CONFIG); true } catch (_: Exception) { false }
                    } else {
                        val store = AuroraTailnetStore(directory)
                        value = when (method) {
                            "readSettings" -> store.readSettings().toMap()
                            "snapshot" -> AuroraVpnService.tailnetSnapshot() ?: run {
                                val settings = store.readSettings()
                                mapOf("schema" to 1, "sessionId" to null, "nodeGeneration" to settings.nodeGeneration,
                                    "publicStatus" to AuroraState.status,
                                    "tailnetStatus" to if (settings.enabled) "stopped" else "disabled", "authAvailable" to false)
                            }
                            else -> AuroraVpnService.withTailnetMaintenance {
                                if (!live()) throw AuroraTailnetStoreFailure("stale")
                                when (method) {
                                    "setEnabled" -> store.setEnabled(generation(args["expectedGeneration"]), args["enabled"] as Boolean) { true }.toMap()
                                    "prepareStart" -> store.prepareStart(generation(args["expectedGeneration"]))?.toMap()
                                    "forget" -> store.forget(args["nodeGeneration"] as String) { true }
                                    else -> throw AuroraTailnetStoreFailure("unsupported")
                                }
                            }
                        }
                    }
                } catch (failure: Exception) {
                    val code = fail(failure)
                    if (method == "forget" && code == "busy") value = "busy" else error = code
                }
                post { finish(value, error) }
            }
        } catch (error: Exception) { finish(null, fail(error)) }
    }

    private fun generation(value: Any?): Long = when (value) {
        is Long -> value
        is Int -> value.toLong()
        else -> throw AuroraTailnetStoreFailure("invalid-state")
    }.also { if (it < 0) throw AuroraTailnetStoreFailure("invalid-state") }

    private fun arguments(method: String, value: Any?): Map<*, *> {
        val keys = when (method) {
            "capability", "readSettings", "snapshot" -> emptySet()
            "setEnabled" -> setOf("expectedGeneration", "enabled")
            "prepareStart" -> setOf("expectedGeneration")
            "forget" -> setOf("nodeGeneration")
            "openAuthentication" -> setOf("sessionId", "nodeGeneration")
            "start" -> setOf("settingsGeneration", "nodeGeneration", "config")
            else -> throw AuroraTailnetStoreFailure("unsupported")
        }
        val args = if (keys.isEmpty()) {
            if (value != null) throw AuroraTailnetStoreFailure("invalid-state")
            emptyMap<String, Any>()
        } else value as? Map<*, *> ?: throw AuroraTailnetStoreFailure("invalid-state")
        if (args.keys != keys) throw AuroraTailnetStoreFailure("invalid-state")
        for (key in keys) {
            val entry = args[key]
            val valid = when (key) {
                "expectedGeneration", "settingsGeneration" -> { generation(entry); true }
                "enabled" -> entry is Boolean
                "sessionId", "nodeGeneration" -> entry is String && uuid.matches(entry)
                "config" -> entry is String && entry.isNotBlank() && entry.length <= 1_048_576 && entry.toByteArray(Charsets.UTF_8).size <= 1_048_576
                else -> false
            }
            if (!valid) throw AuroraTailnetStoreFailure("invalid-state")
        }
        return args.toMap()
    }
}
