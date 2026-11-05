package com.aurora.vpn

import java.io.File
import java.io.Closeable
import java.util.UUID

class AuroraTailnetStoreFailure(val code: String) : Exception(code)

// Native callers supply Context.noBackupFilesDir, never a path received on a channel.
// This class does not start a core. The service must retain Lease until real close
// completes; a timeout or a disconnected status is not permission to close it.
// Construct/use it on the native worker, not Android's main thread.
class AuroraTailnetStore(noBackupDirectory: File) {
    private val files = AuroraTailnetStoreFiles(noBackupDirectory)
    data class Settings(val settingsGeneration: Long, val enabled: Boolean, val nodeGeneration: String?) {
        fun toMap(): Map<String, Any?> = mapOf("schema" to 1, "settingsGeneration" to settingsGeneration,
            "enabled" to enabled, "nodeGeneration" to nodeGeneration)
    }
    data class Prepared(val settingsGeneration: Long, val nodeGeneration: String,
                        val stateDirectory: String, val hostname: String) {
        fun toMap(): Map<String, Any> = mapOf("schema" to 1, "settingsGeneration" to settingsGeneration,
            "nodeGeneration" to nodeGeneration, "stateDirectory" to stateDirectory, "hostname" to hostname)
    }
    class Lease internal constructor(val prepared: Prepared, val sessionId: String,
                                      private val lock: Closeable) : Closeable {
        @Synchronized override fun close() {
            try { lock.close() } catch (_: Exception) { throw AuroraTailnetStoreFailure("storage") }
        }
    }
    private data class Record(val settings: Settings, val phase: String)

    fun readSettings(): Settings = safely { read().settings }

    fun setEnabled(expected: Long, enabled: Boolean, requireStopped: () -> Boolean): Settings = locked {
        val record = read()
        requireExpected(record, expected)
        if (record.phase == "forgetting") fail("invalid-state")
        if (!requireStopped()) fail("busy")
        if (record.settings.enabled == enabled) return@locked record.settings
        val next = record.copy(settings = record.settings.copy(
            settingsGeneration = increment(expected), enabled = enabled))
        write(next)
        next.settings
    }

    fun prepareStart(expected: Long): Prepared? = locked {
        var record = read()
        requireExpected(record, expected)
        if (record.phase == "forgetting") fail("invalid-state")
        if (!record.settings.enabled) return@locked null
        if (record.phase == "none") {
            record = record.copy(settings = record.settings.copy(nodeGeneration = UUID.randomUUID().toString()),
                phase = "allocated")
            // Persist the identity before creating its directory. A crash may
            // resume this same empty allocation, never adopt unknown core state.
            write(record)
        }
        val node = record.settings.nodeGeneration!!
        if (record.phase == "allocated") {
            files.allocateNode(node)
            record = record.copy(phase = "ready")
            write(record)
        }
        context(record)
    }

    fun acquireSessionLease(prepared: Prepared, sessionId: String): Lease = safely {
        requireUuid(sessionId)
        val lock = files.acquire()
        try {
            val record = read()
            if (record.phase != "ready" || !record.settings.enabled || context(record) != prepared) fail("stale")
            Lease(context(record), sessionId, lock)
        } catch (error: Throwable) { lock.close(); throw error }
    }

    fun forget(nodeGeneration: String, requireStopped: () -> Boolean): String = try {
        locked {
            requireUuid(nodeGeneration)
            var record = read()
            if (record.settings.nodeGeneration != nodeGeneration) return@locked "stale"
            if (!requireStopped()) return@locked "busy"
            if (record.phase != "forgetting") {
                record = record.copy(settings = record.settings.copy(enabled = false,
                    settingsGeneration = increment(record.settings.settingsGeneration)), phase = "forgetting")
                // A failed/partial deletion remains a tombstone. No new start or
                // setting change is allowed until explicit forget finishes.
                write(record)
            }
            files.removeNode(nodeGeneration)
            write(record.copy(settings = record.settings.copy(nodeGeneration = null), phase = "none"))
            "forgotten"
        }
    } catch (error: AuroraTailnetStoreFailure) {
        if (error.code == "busy") "busy" else throw error
    }

    private fun context(record: Record): Prepared {
        val node = record.settings.nodeGeneration ?: fail("invalid-state")
        return Prepared(record.settings.settingsGeneration, node, files.nodePath(node),
            "aurora-${node.substring(0, 8).lowercase()}")
    }

    private fun read(): Record {
        val text = files.readMetadata()
        val record = if (text == null) Record(Settings(0, false, null), "none") else {
            // Canonical private metadata: no credentials, arbitrary strings,
            // unknown fields, duplicate keys, floating-point or truncated values.
            val match = FORMAT.matchEntire(text) ?: fail("invalid-state")
            val generation = match.groupValues[1].toLongOrNull() ?: fail("invalid-state")
            val node = match.groupValues[3].let { if (it == "null") null else it.substring(1, it.length - 1) }
            if (node != null) requireUuid(node)
            val phase = match.groupValues[4]
            if ((node == null) != (phase == "none")) fail("invalid-state")
            if (phase == "forgetting" && match.groupValues[2] != "false") fail("invalid-state")
            Record(Settings(generation, match.groupValues[2] == "true", node), phase)
        }
        files.validateLayout(record.settings.nodeGeneration, record.phase)
        return record
    }

    private fun write(record: Record) {
        val s = record.settings
        val node = s.nodeGeneration?.let { "\"$it\"" } ?: "null"
        files.writeMetadata("{\"schema\":1,\"settingsGeneration\":${s.settingsGeneration},\"enabled\":${s.enabled},\"nodeGeneration\":$node,\"phase\":\"${record.phase}\"}\n")
    }
    private fun requireExpected(record: Record, expected: Long) {
        if (expected < 0) fail("invalid-state")
        if (record.settings.settingsGeneration != expected) fail("stale")
    }
    private fun increment(value: Long): Long {
        if (value == Long.MAX_VALUE) fail("invalid-state")
        return value + 1
    }
    private fun <T> locked(action: () -> T): T = safely { files.acquire().use { action() } }
    private fun <T> safely(action: () -> T): T = try { action() }
        catch (error: AuroraTailnetStoreFailure) { throw error }
        catch (_: Exception) { fail("storage") }
    companion object {
        private val UUID_FORMAT = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        private val FORMAT = Regex("\\{\"schema\":1,\"settingsGeneration\":(0|[1-9][0-9]*),\"enabled\":(true|false),\"nodeGeneration\":(null|\"[^\"]*\"),\"phase\":\"(none|allocated|ready|forgetting)\"}\\n")
        private fun requireUuid(value: String) { if (!UUID_FORMAT.matches(value)) fail("invalid-state") }
        private fun fail(code: String): Nothing = throw AuroraTailnetStoreFailure(code)
    }
}
