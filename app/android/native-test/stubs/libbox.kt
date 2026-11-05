@file:Suppress("UNUSED_PARAMETER")
package io.nekohasekai.libbox
import java.util.concurrent.CopyOnWriteArrayList
interface StringIterator {fun hasNext():Boolean;fun next():String;fun len():Int}
interface NetworkInterfaceIterator {fun hasNext():Boolean;fun next():NetworkInterface}
class NetworkInterface {fun setName(v:String){};fun setIndex(v:Int){};fun setMTU(v:Int){};fun setFlags(v:Int){};fun setAddresses(v:StringIterator){};fun setDNSServer(v:StringIterator){};fun setType(v:Int){};fun setMetered(v:Boolean){} }
class ConnectionOwner;class LocalDNSTransport;class WIFIState
class Notification {
 private var identifier="";private var typeID=0;private var openURL=""
 fun getIdentifier()=identifier;fun setIdentifier(v:String){identifier=v}
 fun getTypeID()=typeID;fun setTypeID(v:Int){typeID=v}
 fun getOpenURL()=openURL;fun setOpenURL(v:String){openURL=v}
 fun getTypeName()="";fun getTitle()="";fun getSubtitle()="";fun getBody()=""
 override fun toString():String=throw AssertionError("Notification must not be rendered")
}
interface InterfaceUpdateListener {fun updateDefaultInterface(name:String,index:Int,expensive:Boolean,constrained:Boolean)}
interface PlatformInterface {
 fun openTun(options:TunOptions):Int;fun usePlatformAutoDetectInterfaceControl():Boolean;fun autoDetectInterfaceControl(fd:Int)
 fun useProcFS():Boolean;fun underNetworkExtension():Boolean;fun includeAllNetworks():Boolean;fun clearDNSCache()
 fun findConnectionOwner(ipProtocol:Int,sourceAddress:String,sourcePort:Int,destinationAddress:String,destinationPort:Int):ConnectionOwner
 fun localDNSTransport():LocalDNSTransport?;fun readWIFIState():WIFIState?;fun sendNotification(notification:Notification)
 fun systemCertificates():StringIterator;fun getInterfaces():NetworkInterfaceIterator
 fun startDefaultInterfaceMonitor(listener:InterfaceUpdateListener);fun closeDefaultInterfaceMonitor(listener:InterfaceUpdateListener)
}
class Prefix {fun address()="10.111.222.1";fun prefix()=24}
class PrefixIterator {fun hasNext()=false;fun next()=Prefix()}
class StringBox(val value:String)
class TunOptions {fun getMTU()=1400;fun getInet4Address()=PrefixIterator();fun getInet6Address()=PrefixIterator();fun getDNSServerAddress():StringBox?=StringBox("1.1.1.1")}
class SetupOptions {var basePath="";var workingPath="";var tempPath=""}
class OverrideOptions
class SystemProxyStatus {var available=false;var enabled=false}
interface CommandServerHandler {fun serviceStop();fun serviceReload();fun getSystemProxyStatus():SystemProxyStatus;fun setSystemProxyEnabled(isEnabled:Boolean);fun writeDebugMessage(message:String)}
open class CommandServer(val handler:CommandServerHandler,val platform:PlatformInterface) {
 @Volatile var closed=false;var config="";var fd=-1;var startCalls=0
 open fun start(){}
 open fun startOrReloadService(config:String,options:OverrideOptions){startCalls++;this.config=config;Libbox.beforeStart?.invoke(this);fd=platform.openTun(TunOptions());Libbox.afterStart?.invoke(this)}
 open fun closeService(){Libbox.beforeClose?.invoke(this)}
 open fun close(){Libbox.beforeListenerClose?.invoke(this);closed=true}
}
class CommandClientOptions {var statusInterval=0L;fun addCommand(c:Int){}}
interface CommandClientHandler {fun connected();fun disconnected(message:String?);fun writeStatus(message:StatusMessage);fun writeGroups(groups:OutboundGroupIterator?);fun writeLogs(messages:LogIterator?);fun writeConnectionEvents(message:ConnectionEvents?);fun clearLogs();fun initializeClashMode(modeList:StringIterator?,currentMode:String?);fun updateClashMode(newMode:String?);fun setDefaultLogLevel(level:Int)}
class ConnectionEvents;interface LogIterator
class StatusMessage {var uplink=0L;var downlink=0L;var uplinkTotal=0L;var downlinkTotal=0L;var memory=0L;var connectionsOut=0L}
class OutboundGroup(val tag:String,val selected:String) {val type="selector";val selectable=true;val items=OutboundItemIterator()}
class OutboundItem {val tag="test";val type="direct";val urlTestDelay=0}
class OutboundItemIterator {fun hasNext()=false;fun next()=OutboundItem()}
class OutboundGroupIterator(val entries:List<OutboundGroup>) {private var index=0;fun hasNext()=index<entries.size;fun next()=entries[index++]}
open class CommandClient(val handler:CommandClientHandler) {
 @Volatile var active=false;val selections=CopyOnWriteArrayList<String>();val urlTests=CopyOnWriteArrayList<String>()
 open fun connect(){Libbox.beforeConnect?.invoke(this);active=true;handler.connected();Libbox.afterConnect?.invoke(this)}
 open fun disconnect(){active=false;handler.disconnected("status cancelled");handler.disconnected("groups cancelled")}
 open fun selectOutbound(group:String,tag:String){Libbox.beforeSelect?.invoke(this);selections.add("$group:$tag");handler.writeGroups(OutboundGroupIterator(listOf(OutboundGroup(group,tag))))}
 open fun urlTest(group:String){Libbox.beforeUrlTest?.invoke(this);check(active){"transport unavailable"};urlTests.add(group)}
 fun breakTransport(){active=false;handler.disconnected("status ended");handler.disconnected("groups ended")}
}
object Libbox {
 const val InterfaceTypeWIFI=1;const val InterfaceTypeCellular=2;const val InterfaceTypeEthernet=3;const val InterfaceTypeOther=4
 const val CommandStatus=1;const val CommandGroup=2
 val servers=CopyOnWriteArrayList<CommandServer>();val clients=CopyOnWriteArrayList<CommandClient>()
 var beforeStart:((CommandServer)->Unit)?=null;var afterStart:((CommandServer)->Unit)?=null;var beforeClose:((CommandServer)->Unit)?=null;var beforeConnect:((CommandClient)->Unit)?=null;var afterConnect:((CommandClient)->Unit)?=null;var beforeSelect:((CommandClient)->Unit)?=null
 var beforeUrlTest:((CommandClient)->Unit)?=null
 var beforeListenerClose:((CommandServer)->Unit)?=null
 var beforeCheckConfig:((String)->Unit)?=null;var setupCalls=0
 fun checkConfig(config:String){beforeCheckConfig?.invoke(config)}
 fun setup(s:SetupOptions){setupCalls++}
 fun newCommandServer(h:CommandServerHandler,p:PlatformInterface)=CommandServer(h,p).also{servers.add(it)}
 fun newCommandClient(h:CommandClientHandler,o:CommandClientOptions)=CommandClient(h).also{clients.add(it)}
}
