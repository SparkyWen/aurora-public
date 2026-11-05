package com.aurora.vpn

import java.util.concurrent.CopyOnWriteArrayList

/**
 * Process-wide VPN state holder. AuroraVpnService / AuroraCommandClient publish
 * status, live traffic stats, and outbound groups; the Flutter EventChannels (in
 * MainActivity) subscribe. Same-process, so a simple observable is enough.
 */
object AuroraState {
    // ---- connection status ----
    @Volatile
    var status: String = "disconnected"
        private set

    private val statusListeners = CopyOnWriteArrayList<(String) -> Unit>()

    fun set(value: String) {
        status = value
        for (l in statusListeners) runCatching { l(value) }
    }

    fun addListener(listener: (String) -> Unit) {
        statusListeners.add(listener)
        runCatching { listener(status) }
    }

    fun removeListener(listener: (String) -> Unit) = statusListeners.remove(listener)

    // ---- live traffic stats ----
    @Volatile
    var stats: Map<String, Any?> = emptyMap()
        private set

    private val statsListeners = CopyOnWriteArrayList<(Map<String, Any?>) -> Unit>()

    fun setStats(value: Map<String, Any?>) {
        stats = value
        for (l in statsListeners) runCatching { l(value) }
    }

    fun addStatsListener(listener: (Map<String, Any?>) -> Unit) {
        statsListeners.add(listener)
        if (stats.isNotEmpty()) runCatching { listener(stats) }
    }

    fun removeStatsListener(listener: (Map<String, Any?>) -> Unit) =
        statsListeners.remove(listener)

    // ---- outbound groups (nodes / delays / selection) ----
    @Volatile
    var groups: List<Map<String, Any?>> = emptyList()
        private set

    private val groupsListeners = CopyOnWriteArrayList<(List<Map<String, Any?>>) -> Unit>()

    fun setGroups(value: List<Map<String, Any?>>) {
        groups = value
        for (l in groupsListeners) runCatching { l(value) }
    }

    fun addGroupsListener(listener: (List<Map<String, Any?>>) -> Unit) {
        groupsListeners.add(listener)
        if (groups.isNotEmpty()) runCatching { listener(groups) }
    }

    fun removeGroupsListener(listener: (List<Map<String, Any?>>) -> Unit) =
        groupsListeners.remove(listener)

    // ---- active command client (for manual select / urltest from the UI) ----
    @Volatile
    var commandClient: AuroraCommandClient? = null

    fun clearDynamic() {
        setStats(emptyMap())
        setGroups(emptyList())
        commandClient = null
    }
}
