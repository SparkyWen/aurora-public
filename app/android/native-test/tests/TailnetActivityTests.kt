package com.aurora.vpn.test
import com.aurora.aurora.MainActivity
import com.aurora.vpn.AuroraVpnService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
fun tailnetActivityTests() {
    val activity = MainActivity()
    activity.configureFlutterEngine(FlutterEngine()); activity.onResume()
    val handler = MethodChannel.handlers["aurora/tailnet"]
    expect(handler != null, "actual MainActivity registers the independent native Tailnet channel")
    if (handler == null) return
    var calls=0; var errorCode: String?=null; var errorMessage: String?=null; var errorDetails: Any?=null
    val reply = object : MethodChannel.Result {
        override fun success(value: Any?) { calls++ }
        override fun error(code: String, message: String?, details: Any?) {errorCode=code;errorMessage=message;errorDetails=details;calls++}
        override fun notImplemented() { errorCode="not-implemented";calls++ }
    }
    val node="ABCDEF12-1234-1234-1234-ABCDEF123456"
    val args=mapOf("config" to "public-fixture", "settingsGeneration" to 3L, "nodeGeneration" to node)
    val prepares=android.net.VpnService.prepareCalls
    handler(MethodCall("start",args),reply)
    expect(calls==1 && errorCode==null && activity.serviceStarts.size==1 && android.net.VpnService.prepareCalls==prepares,
        "explicit Tailnet channel start dispatches once without preparing another VPN")
    val intent=activity.serviceStarts.single()
    expect(intent.getLongExtra(AuroraVpnService.EXTRA_TAILNET_GENERATION,-1)==3L &&
        intent.getStringExtra(AuroraVpnService.EXTRA_TAILNET_NODE)==node,
        "actual Activity passes native generation and case-preserved node through the Service intent")
    activity.onPause()
    handler(MethodCall("start",args),reply)
    expect(errorCode=="busy" && errorDetails==null && errorMessage=="Tailnet operation failed" && activity.serviceStarts.size==1,
        "actual Activity lifecycle refuses background start and exposes only fixed error text")
    activity.onDestroy()
    expect(MethodChannel.handlers["aurora/tailnet"]==null, "destroyed Activity removes its new channel handler")
    errorCode=null
    handler(MethodCall("start",args),reply)
    expect(errorCode=="stale" && activity.serviceStarts.size==1, "a retained old Activity handler cannot launch a late Service")
}
