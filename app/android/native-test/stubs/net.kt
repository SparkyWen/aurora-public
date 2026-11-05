@file:Suppress("UNUSED_PARAMETER")
package android.net
import android.content.Context
import android.content.Intent
import android.app.Notification
import android.os.ParcelFileDescriptor
import java.util.concurrent.CopyOnWriteArrayList
class Network(val id:Int) { override fun toString()=id.toString() }
class NetworkCapabilities {
 companion object { const val NET_CAPABILITY_INTERNET=12;const val NET_CAPABILITY_NOT_VPN=15;const val NET_CAPABILITY_NOT_METERED=11;const val NET_CAPABILITY_VALIDATED=16; const val TRANSPORT_WIFI=1;const val TRANSPORT_CELLULAR=0;const val TRANSPORT_ETHERNET=3;const val TRANSPORT_VPN=4 }
 val capabilities=mutableSetOf<Int>();val transports=mutableSetOf<Int>()
 fun hasCapability(c:Int)=c in capabilities
 fun hasTransport(t:Int)=t in transports
}
class LinkProperties(var interfaceName:String?=null)
class NetworkRequest { class Builder { fun addCapability(c:Int)=this;fun build()=NetworkRequest() } }
class ConnectivityManager {
 open class NetworkCallback {
 open fun onAvailable(network:Network){};open fun onCapabilitiesChanged(network:Network,caps:NetworkCapabilities){}
 open fun onLinkPropertiesChanged(network:Network,properties:LinkProperties){};open fun onLost(network:Network){}
 }
 val callbacks=CopyOnWriteArrayList<NetworkCallback>()
 val capabilities=mutableMapOf<Network,NetworkCapabilities>();val links=mutableMapOf<Network,LinkProperties>()
 var activeNetwork:Network?=null
 fun registerNetworkCallback(r:NetworkRequest,c:NetworkCallback){callbacks.add(c)}
 fun unregisterNetworkCallback(c:NetworkCallback){callbacks.remove(c)}
 fun getLinkProperties(n:Network)=links[n]
 fun getNetworkCapabilities(n:Network)=capabilities[n]
}
open class VpnService:Context() {
 companion object { var prepareCalls = 0; fun prepare(context:Context):Intent? {prepareCalls++;return null}; const val START_STICKY=1;const val START_NOT_STICKY=2;const val STOP_FOREGROUND_REMOVE=1;var beforeEstablish:(()->Unit)?=null;val established=CopyOnWriteArrayList<ParcelFileDescriptor>() }
 open fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int=0
 open fun onDestroy(){};open fun onRevoke(){}
 fun protect(fd:Int)=true
 fun startForeground(id:Int,n:Notification){
  check(android.os.Build.VERSION.SDK_INT < 26 || !n.channelId.isNullOrBlank()) { "modern foreground notification requires a channel" }
 };fun startForeground(id:Int,n:Notification,type:Int){startForeground(id,n)}
 var stopSelfResultCalls=0
 fun stopForeground(flags:Int){};fun stopSelf(){};fun stopSelfResult(id:Int):Boolean {stopSelfResultCalls++;return true}
 inner class Builder {
 fun setMtu(v:Int)=this;fun addAddress(a:String,p:Int)=this;fun addRoute(a:String,p:Int)=this
 fun addDnsServer(v:String)=this;fun setSession(v:String)=this;fun setMetered(v:Boolean)=this
 fun establish():ParcelFileDescriptor { beforeEstablish?.invoke(); return ParcelFileDescriptor().also{established.add(it)} }
 }
}

class Uri private constructor(val value:String) {companion object {fun parse(value:String)=Uri(value)}}
