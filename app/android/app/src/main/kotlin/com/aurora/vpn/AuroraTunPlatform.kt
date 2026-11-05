package com.aurora.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.NetworkInterfaceIterator
import java.net.NetworkInterface as JavaNetworkInterface
import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface

/**
 * libbox PlatformInterface implementation. libbox drives the VpnService through this:
 *  - openTun -> build the Android TUN
 *  - autoDetectInterfaceControl -> VpnService.protect(fd) (anti-loop; without this every
 *    request times out and CPU spikes)
 *  - getInterfaces / default-interface monitor -> the platform wrapper hardcodes
 *    UsePlatformNetworkInterfaces=true and UsePlatformDefaultInterfaceMonitor=true,
 *    so these MUST be implemented for traffic to egress correctly.
 */
class AuroraTunPlatform(
    private val svc: AuroraVpnService,
    context: Context,
    private val onNotification: (Notification) -> Unit = {},
    private val openTunnel: (TunOptions) -> Int = svc::establishTun,
) : PlatformInterface {

    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val monitorLock = Any()
    private data class Candidate(
        var capabilities: NetworkCapabilities? = null,
        var properties: LinkProperties? = null,
    )
    private data class DefaultInterface(val name: String, val index: Int, val metered: Boolean)
    private val networks = mutableMapOf<Network, Candidate>()
    private var reportedNetwork: Network? = null
    private var reportedInterface: DefaultInterface? = null

    // ---- TUN + anti-loop socket protection ----

    override fun openTun(options: TunOptions): Int = openTunnel(options)

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!svc.protect(fd)) {
            Log.w(AuroraVpnService.TAG, "protect(fd=$fd) returned false")
        }
    }

    override fun useProcFS(): Boolean = false

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner = throw UnsupportedOperationException("process matching not supported")

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun readWIFIState(): WIFIState? = null

    override fun sendNotification(notification: Notification) { onNotification(notification) }

    override fun systemCertificates(): StringIterator = StringArrayIterator(emptyList())

    // ---- network interface enumeration ----

    override fun getInterfaces(): NetworkInterfaceIterator {
        val out = ArrayList<BoxNetworkInterface>()
        val ifaces = try {
            JavaNetworkInterface.getNetworkInterfaces()
        } catch (e: Exception) {
            null
        } ?: return NetworkInterfaceArrayIterator(out)

        for (ni in ifaces) {
            val box = BoxNetworkInterface()
            box.setName(ni.name)
            try { box.setIndex(ni.index) } catch (_: Exception) {}
            try { box.setMTU(ni.mtu) } catch (_: Exception) {}

            var flags = 0
            try {
                if (ni.isUp) flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                if (ni.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                if (ni.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
                if (ni.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            } catch (_: Exception) {}
            box.setFlags(flags)

            val addresses = ArrayList<String>()
            for (ia in ni.interfaceAddresses) {
                val raw = ia.address?.hostAddress ?: continue
                // Strip IPv6 zone id (e.g. "fe80::1%dummy0") — sing-box's netip.ParsePrefix
                // rejects zones in a prefix and panics otherwise.
                val host = raw.substringBefore('%')
                addresses.add("$host/${ia.networkPrefixLength}")
            }
            box.setAddresses(StringArrayIterator(addresses))
            box.setDNSServer(StringArrayIterator(emptyList()))
            box.setType(interfaceType(ni.name))
            box.setMetered(false)
            out.add(box)
        }
        return NetworkInterfaceArrayIterator(out)
    }

    private fun interfaceType(name: String): Int = when {
        name.startsWith("wlan") -> Libbox.InterfaceTypeWIFI
        name.startsWith("rmnet") || name.startsWith("ccmni") || name.startsWith("pdp") ->
            Libbox.InterfaceTypeCellular
        name.startsWith("eth") -> Libbox.InterfaceTypeEthernet
        else -> Libbox.InterfaceTypeOther
    }

    // ---- default interface monitor (ConnectivityManager) ----

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        close()
        val callback = object : ConnectivityManager.NetworkCallback() {
            private fun changed(network: Network, update: (Candidate) -> Unit) {
                synchronized(monitorLock) {
                    if (networkCallback !== this) return
                    update(networks.getOrPut(network) { Candidate() })
                    reportDefault(listener)
                }
            }

            override fun onAvailable(network: Network) {
                changed(network) { candidate ->
                    // Only API 26+ guarantees the initial capabilities and
                    // LinkProperties callbacks. Nougat needs this snapshot to
                    // discover an existing stable network; newer releases wait
                    // for ordered callbacks to avoid reading stale properties.
                    if (Build.VERSION.SDK_INT < 26) {
                        candidate.capabilities = connectivity.getNetworkCapabilities(network)
                        candidate.properties = connectivity.getLinkProperties(network)
                    }
                }
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                changed(network) { it.capabilities = caps }
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                changed(network) { it.properties = properties }
            }

            override fun onLost(network: Network) {
                synchronized(monitorLock) {
                    if (networkCallback !== this) return
                    networks.remove(network)
                    reportDefault(listener)
                }
            }
        }
        synchronized(monitorLock) { networkCallback = callback }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        try {
            connectivity.registerNetworkCallback(request, callback)
        } catch (e: Exception) {
            synchronized(monitorLock) {
                if (networkCallback === callback) networkCallback = null
            }
            throw IllegalStateException("cannot monitor the underlying network", e)
        }
        // A concurrent close may have invalidated us before registration finished.
        synchronized(monitorLock) {
            if (networkCallback !== callback) {
                runCatching { connectivity.unregisterNetworkCallback(callback) }
            }
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        close()
    }

    // monitorLock serializes selection, listener delivery and cancellation. Only
    // complete, non-VPN candidates can win; a late cellular event cannot erase
    // Wi-Fi. The OS default wins when it is physical. While activeNetwork is our
    // VPN, prefer validated Ethernet/Wi-Fi, keeping ties stable across callbacks.
    private fun reportDefault(listener: InterfaceUpdateListener) {
        val usable = networks.mapNotNull { (network, candidate) ->
            val caps = candidate.capabilities ?: return@mapNotNull null
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@mapNotNull null
            val name = candidate.properties?.interfaceName ?: return@mapNotNull null
            val index = runCatching { JavaNetworkInterface.getByName(name)?.index }.getOrNull()
                ?: return@mapNotNull null
            if (index < 0) return@mapNotNull null
            network to DefaultInterface(name, index,
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
        }.toMap()
        val active = connectivity.activeNetwork
        val selected = if (active in usable) active else usable.keys.minWithOrNull(
            compareBy<Network>(
                { if (networks[it]!!.capabilities!!.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 0 else 1 },
                {
                    val caps = networks[it]!!.capabilities!!
                    when {
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 0
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 1
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
                        else -> 3
                    }
                },
                { if (it == reportedNetwork) 0 else 1 },
                { it.toString() },
            )
        )
        val next = usable[selected] ?: DefaultInterface("", -1, false)
        reportedNetwork = selected
        if (next != reportedInterface) {
            reportedInterface = next
            listener.updateDefaultInterface(next.name, next.index, next.metered, false)
        }
    }

    fun close() {
        val callback = synchronized(monitorLock) {
            val current = networkCallback
            networkCallback = null
            networks.clear()
            reportedNetwork = null
            reportedInterface = null
            current
        }
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
    }

    // ---- libbox iterator adapters ----

    private class StringArrayIterator(private val items: List<String>) : StringIterator {
        private var index = 0
        override fun hasNext(): Boolean = index < items.size
        override fun next(): String = items[index++]
        override fun len(): Int = items.size
    }

    private class NetworkInterfaceArrayIterator(
        private val items: List<BoxNetworkInterface>,
    ) : NetworkInterfaceIterator {
        private var index = 0
        override fun hasNext(): Boolean = index < items.size
        override fun next(): BoxNetworkInterface = items[index++]
    }
}
