package com.aurora.vpn

import android.util.Log
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Streams libbox state and accepts commands until group-stream readback confirms them. */
class AuroraCommandClient(private val privateErrors: Boolean = false) {
    companion object {
        // Disconnect can wait for a cgo dial's mutex. Never wait for it from a
        // native callback, the UI thread, or while holding our state lock.
        private val cleanup = Executors.newCachedThreadPool { task ->
            Thread(task, "aurora-command-close").apply { isDaemon = true }
        }
    }

    private data class Selection(val tag: String, val revision: Long)
    private class Pending<T>(val value: T) {
        var failures = 0
        var nextAttemptNanos = System.nanoTime()
    }
    private val lock = Any()
    private var running = false
    private var connected = false
    private var generation = 0
    private var revision = 0L
    private var failures = 0
    private var client: CommandClient? = null
    private var executor: ScheduledExecutorService? = null
    private var retry: ScheduledFuture<*>? = null
    private var replayTask: ScheduledFuture<*>? = null
    private var replaySerial = 0L
    private var replayAtNanos = 0L
    private val desiredSelections = mutableMapOf<String, Selection>()
    private val pendingSelections = mutableMapOf<String, Pending<Selection>>()
    private val pendingTests = mutableMapOf<String, Pending<Long>>()

    fun start() {
        synchronized(lock) {
            if (running) return
            running = true
            failures = 0
            executor = ScheduledThreadPoolExecutor(1) { task ->
                Thread(task, "aurora-command").apply { isDaemon = true }
            }.apply { removeOnCancelPolicy = true }
            scheduleConnectLocked(0)
        }
    }

    private fun current(gen: Int) = running && gen == generation

    private fun scheduleConnectLocked(delayMillis: Long) {
        if (!running || retry != null) return
        val gen = ++generation
        retry = executor!!.schedule({ connect(gen) }, delayMillis, TimeUnit.MILLISECONDS)
    }

    private fun connect(gen: Int) {
        synchronized(lock) {
            if (!current(gen)) return
            retry = null
        }
        val options = CommandClientOptions().apply {
            statusInterval = 1_000_000_000L
            addCommand(Libbox.CommandStatus)
            addCommand(Libbox.CommandGroup)
        }
        val transport = Libbox.newCommandClient(handler(gen), options)
        val accepted = synchronized(lock) {
            if (!current(gen)) false else { client = transport; true }
        }
        if (!accepted) { retire(transport); return }
        try {
            transport.connect()
        } catch (error: Exception) {
            Log.w(AuroraVpnService.TAG, "command connect failed", if (privateErrors) null else error)
            disconnected(gen)
        } finally {
            // stop/disconnect may have happened while the synchronous cgo dial
            // was running. Closing before it finished was not sufficient.
            if (!synchronized(lock) { current(gen) && client === transport }) retire(transport)
        }
    }

    private fun disconnected(gen: Int) {
        val retired = synchronized(lock) {
            if (!current(gen)) return
            connected = false
            cancelReplayLocked()
            val previous = client
            client = null
            // Scheduling advances generation immediately: status+group errors
            // and late callbacks from this transport cannot schedule a second dial.
            val delay = (500L shl minOf(failures++, 4)).coerceAtMost(10_000L)
            scheduleConnectLocked(delay)
            previous
        }
        retire(retired)
    }

    private fun queueReplayLocked(gen: Int) {
        if (!current(gen) || !connected) return
        val at = (pendingSelections.values.asSequence().map { it.nextAttemptNanos } +
            pendingTests.values.asSequence().map { it.nextAttemptNanos }).minOrNull() ?: return
        if (replayTask != null && replayAtNanos <= at) return
        replayTask?.cancel(false)
        val serial = ++replaySerial
        replayAtNanos = at
        replayTask = executor!!.schedule({ replay(gen, serial) },
            (at - System.nanoTime()).coerceAtLeast(0), TimeUnit.NANOSECONDS)
    }

    private fun cancelReplayLocked() {
        replayTask?.cancel(false)
        replayTask = null
        replaySerial++
    }

    private fun replay(gen: Int, serial: Long) {
        val transport: CommandClient
        val selections: Map<String, Pending<Selection>>
        val tests: Map<String, Pending<Long>>
        synchronized(lock) {
            if (!current(gen) || !connected || serial != replaySerial) return
            replayTask = null
            transport = client ?: return
            val now = System.nanoTime()
            selections = pendingSelections.filterValues { it.nextAttemptNanos <= now }
            tests = pendingTests.filterValues { it.nextAttemptNanos <= now }
        }
        for ((group, request) in selections) {
            val eligible = synchronized(lock) {
                current(gen) && connected && pendingSelections[group] === request
            }
            if (!eligible) continue
            // Native RPCs run in order on the worker, without holding state.
            runCatching { transport.selectOutbound(group, request.value.tag) }
                .onSuccess {
                    synchronized(lock) {
                        if (current(gen) && pendingSelections[group] === request) pendingSelections.remove(group)
                    }
                }.onFailure { error ->
                    synchronized(lock) {
                        if (current(gen) && pendingSelections[group] === request && !retryRequestLocked(request)) {
                            pendingSelections.remove(group)
                            if (desiredSelections[group] == request.value) desiredSelections.remove(group)
                            Log.w(AuroraVpnService.TAG, "selectOutbound retry budget exhausted", if (privateErrors) null else error)
                        }
                    }
                }
        }
        for ((group, request) in tests) {
            val eligible = synchronized(lock) {
                current(gen) && connected && pendingTests[group] === request
            }
            if (!eligible) continue
            runCatching { transport.urlTest(group) }
                .onSuccess {
                    synchronized(lock) {
                        if (current(gen) && pendingTests[group] === request) pendingTests.remove(group)
                    }
                }.onFailure { error ->
                    synchronized(lock) {
                        if (current(gen) && pendingTests[group] === request && !retryRequestLocked(request)) {
                            pendingTests.remove(group)
                            Log.w(AuroraVpnService.TAG, "urlTest retry budget exhausted", if (privateErrors) null else error)
                        }
                    }
                }
        }
        synchronized(lock) { queueReplayLocked(gen) }
    }

    private fun retryRequestLocked(request: Pending<*>): Boolean {
        // An independent unary RPC failure need not end the healthy status/group
        // streams. Give each revision two delayed retries.
        if (++request.failures >= 3) return false
        request.nextAttemptNanos = System.nanoTime() +
            TimeUnit.MILLISECONDS.toNanos(250L shl (request.failures - 1))
        return true
    }

    private fun handler(gen: Int) = object : CommandClientHandler {
        override fun connected() {
            synchronized(lock) {
                if (!current(gen)) return
                connected = true
                failures = 0
                for ((group, selection) in desiredSelections) {
                    if (pendingSelections[group]?.value != selection) pendingSelections[group] = Pending(selection)
                }
                queueReplayLocked(gen)
            }
        }

        override fun disconnected(message: String?) { disconnected(gen) }

        override fun writeStatus(message: StatusMessage) {
            synchronized(lock) {
                if (!current(gen) || !connected) return
                AuroraState.setStats(mapOf(
                    "uplink" to message.uplink,
                    "downlink" to message.downlink,
                    "uplinkTotal" to message.uplinkTotal,
                    "downlinkTotal" to message.downlinkTotal,
                    "memory" to message.memory,
                    "connectionsOut" to message.connectionsOut,
                ))
            }
        }

        override fun writeGroups(groups: OutboundGroupIterator?) {
            synchronized(lock) {
                if (!current(gen) || !connected) return
                if (groups == null) return
                val out = ArrayList<Map<String, Any?>>()
                while (groups.hasNext()) {
                    val g = groups.next()
                    val items = ArrayList<Map<String, Any?>>()
                    val it = g.items
                    while (it.hasNext()) {
                        val item = it.next()
                        items.add(
                            mapOf(
                                "tag" to item.tag,
                                "type" to item.type,
                                "delay" to item.urlTestDelay,
                            )
                        )
                    }
                    out.add(
                        mapOf(
                            "tag" to g.tag,
                            "type" to g.type,
                            "selected" to g.selected,
                            "selectable" to g.selectable,
                            "items" to items,
                        )
                    )
                }
                AuroraState.setGroups(out)
            }
        }

        override fun writeLogs(messages: LogIterator?) {}
        override fun writeConnectionEvents(message: ConnectionEvents?) {}
        override fun clearLogs() {}
        override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) {}
        override fun updateClashMode(newMode: String?) {}
        override fun setDefaultLogLevel(level: Int) {}
    }

    fun selectOutbound(group: String, tag: String) {
        synchronized(lock) {
            check(running) { "command client unavailable" }
            val selection = Selection(tag, ++revision)
            desiredSelections[group] = selection
            pendingSelections[group] = Pending(selection)
            queueReplayLocked(generation)
        }
    }

    fun urlTest(group: String) {
        synchronized(lock) {
            if (!running) return
            pendingTests[group] = Pending(++revision)
            queueReplayLocked(generation)
        }
    }

    fun stop() {
        val retired: CommandClient?
        val worker: ScheduledExecutorService?
        synchronized(lock) {
            running = false
            connected = false
            generation++
            retry?.cancel(false)
            retry = null
            cancelReplayLocked()
            desiredSelections.clear()
            pendingSelections.clear()
            pendingTests.clear()
            retired = client
            client = null
            worker = executor
            executor = null
        }
        // The in-flight JNI call is not interruptible; its finally block closes
        // a late connection. Queued work sees the invalid generation and returns.
        worker?.shutdown()
        retire(retired)
    }

    private fun retire(transport: CommandClient?) {
        if (transport != null) cleanup.execute { runCatching { transport.disconnect() } }
    }
}
