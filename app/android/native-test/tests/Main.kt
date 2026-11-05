package com.aurora.vpn.test
import com.aurora.vpn.AuroraTunPlatform
import com.aurora.vpn.AuroraVpnService
import android.net.*
import android.os.Build
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.net.NetworkInterface
private var failures=0
private var checks=0
fun expect(ok:Boolean,message:String){checks++;if(!ok){println("FAIL: $message");failures++}}
fun initialNetworkTests() {
 val originalSdk = Build.VERSION.SDK_INT
 try {
  for (sdk in listOf(24, 25, 26, originalSdk).distinct()) {
   Build.VERSION.SDK_INT = sdk
   val service = AuroraVpnService()
   val cm = service.connectivity
   val platform = AuroraTunPlatform(service, service)
   val reports = mutableListOf<String>()
   val listener = object : InterfaceUpdateListener {
    override fun updateDefaultInterface(name:String,index:Int,expensive:Boolean,constrained:Boolean) { reports.add(name) }
   }
   val name = NetworkInterface.getNetworkInterfaces().toList().first().name
   val wifi = Network(100 + sdk)
   val caps = NetworkCapabilities().apply {
    capabilities.addAll(listOf(NetworkCapabilities.NET_CAPABILITY_INTERNET,
     NetworkCapabilities.NET_CAPABILITY_NOT_VPN, NetworkCapabilities.NET_CAPABILITY_VALIDATED))
    transports.add(NetworkCapabilities.TRANSPORT_WIFI)
   }
   cm.activeNetwork = wifi
   cm.capabilities[wifi] = caps
   cm.links[wifi] = LinkProperties(name)
   platform.startDefaultInterfaceMonitor(listener)
   val callback = cm.callbacks.last()
   // Nougat delivers only onAvailable for a stable network already present at registration.
   callback.onAvailable(wifi)
   if (sdk < 26) {
    expect(reports.lastOrNull() == name, "API $sdk must discover an existing Wi-Fi from onAvailable alone")
   } else {
    expect(reports.none { it.isNotEmpty() }, "API $sdk must not use a potentially stale synchronous initial snapshot")
    callback.onCapabilitiesChanged(wifi, caps)
    expect(reports.none { it.isNotEmpty() }, "API $sdk must wait for initial LinkProperties")
    callback.onLinkPropertiesChanged(wifi, LinkProperties(name))
    expect(reports.lastOrNull() == name, "API $sdk must use the ordered initial network callbacks")
   }
   platform.close()
  }
 } finally {
  Build.VERSION.SDK_INT = originalSdk
 }
}
fun networkTests(){
 val service=AuroraVpnService();val cm=service.connectivity;val platform=AuroraTunPlatform(service,service)
 val reports=mutableListOf<String>()
 val listener=object:InterfaceUpdateListener {override fun updateDefaultInterface(name:String,index:Int,expensive:Boolean,constrained:Boolean){reports.add(name)}}
 val names=NetworkInterface.getNetworkInterfaces().toList().map{it.name}
 val wifiName=names.first();val cellName=names.last()
 val wifi=Network(1);val cell=Network(2)
 fun caps(transport:Int)=NetworkCapabilities().apply {capabilities.addAll(listOf(NetworkCapabilities.NET_CAPABILITY_INTERNET,NetworkCapabilities.NET_CAPABILITY_NOT_VPN,NetworkCapabilities.NET_CAPABILITY_VALIDATED));transports.add(transport)}
 val wifiCaps=caps(NetworkCapabilities.TRANSPORT_WIFI);val cellCaps=caps(NetworkCapabilities.TRANSPORT_CELLULAR)
 platform.startDefaultInterfaceMonitor(listener);val callback=cm.callbacks.last()
 fun available(n:Network,c:NetworkCapabilities,name:String){cm.capabilities[n]=c;cm.links[n]=LinkProperties(name);callback.onAvailable(n);callback.onCapabilitiesChanged(n,c);callback.onLinkPropertiesChanged(n,cm.links[n]!!)}
 available(wifi,wifiCaps,wifiName);available(cell,cellCaps,cellName)
 callback.onCapabilitiesChanged(cell,cellCaps);callback.onLost(cell)
 expect(reports.lastOrNull()==wifiName,"cellular churn must preserve available Wi-Fi, got ${reports.lastOrNull()}")
 callback.onLost(wifi)
 expect(reports.lastOrNull()=="","losing all physical networks must clear default")
 // Real OS callbacks can deliver capabilities before LinkProperties.
 val late=Network(3);cm.capabilities[late]=wifiCaps
 callback.onAvailable(late);callback.onCapabilitiesChanged(late,wifiCaps)
 cm.links[late]=LinkProperties(wifiName);callback.onLinkPropertiesChanged(late,cm.links[late]!!)
 expect(reports.lastOrNull()==wifiName,"late LinkProperties must restore the physical default")
 available(cell,cellCaps,cellName)
 callback.onLost(late)
 expect(reports.lastOrNull()==cellName,"losing selected Wi-Fi must immediately fall back to live cellular")
 available(wifi,wifiCaps,wifiName)
 expect(reports.lastOrNull()==wifiName,"validated Wi-Fi must beat a background cellular event")
 cm.activeNetwork=cell;callback.onCapabilitiesChanged(cell,cellCaps)
 expect(reports.lastOrNull()==cellName,"a physical OS default must take precedence over transport preference")
 cm.activeNetwork=Network(99)
 val unvalidated=NetworkCapabilities().apply {capabilities.addAll(listOf(NetworkCapabilities.NET_CAPABILITY_INTERNET,NetworkCapabilities.NET_CAPABILITY_NOT_VPN));transports.add(NetworkCapabilities.TRANSPORT_WIFI)}
 callback.onCapabilitiesChanged(wifi,unvalidated)
 expect(reports.lastOrNull()==cellName,"validated cellular must beat an unvalidated Wi-Fi candidate")
 val vpn=Network(4);val vpnCaps=caps(NetworkCapabilities.TRANSPORT_VPN)
 available(vpn,vpnCaps,wifiName)
 expect(reports.lastOrNull()==cellName,"a VPN transport must never become the physical default")
 platform.close();val count=reports.size
 callback.onCapabilitiesChanged(cell,cellCaps)
 expect(reports.size==count,"closed monitor must reject delayed callbacks")
}
fun main(args: Array<String>) {
    val suite = args.firstOrNull() ?: "all"
    if (suite == "tailnet-lock-probe") { tailnetLockProbe(args[1]); return }
    if (suite == "all" || suite == "tailnet-store") tailnetStoreTests()
    if (suite == "all" || suite == "tailnet-auth") tailnetAuthTests()
    if (suite == "all" || suite == "tailnet-config") tailnetConfigTests()
    if (suite == "all" || suite == "tailnet-service") tailnetIntegrationTests()
    if (suite == "all" || suite == "tailnet-channel") { tailnetChannelTests(); tailnetActivityTests() }
    if (suite == "tailnet-poison") tailnetPoisonTests(args[1])
    if (suite !in setOf("tailnet-store", "tailnet-auth", "tailnet-config", "tailnet-service", "tailnet-poison", "tailnet-channel")) {
    initialNetworkTests()
    networkTests()
    if (suite != "network") serviceTests(includeReplacement = suite != "service-basic")
    if (suite == "all" || suite == "command") commandTests()
    if (suite == "all" || suite == "recovery") { recoveryTests(); recoveryRaceTests() }
    }
    if (failures > 0) throw AssertionError("$failures native regression(s) failed")
    println("PASS: $checks Android native regression checks")
}
