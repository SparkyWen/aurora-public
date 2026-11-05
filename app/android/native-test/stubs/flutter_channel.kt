@file:Suppress("UNUSED_PARAMETER")
package io.flutter.plugin.common
class MethodCall(val method: String, val arguments: Any?) {
 @Suppress("UNCHECKED_CAST") fun <T> argument(key: String): T? = (arguments as? Map<*, *>)?.get(key) as? T
}
class MethodChannel(messenger: Any, val name: String) {
 interface Result { fun success(value: Any?); fun error(code: String, message: String?, details: Any?); fun notImplemented() }
 companion object { val handlers=mutableMapOf<String, ((MethodCall, Result) -> Unit)?>() }
 fun setMethodCallHandler(handler: ((MethodCall, Result) -> Unit)?) { handlers[name] = handler }
}
class EventChannel(messenger: Any, name: String) {
 interface EventSink { fun success(value: Any?) }
 interface StreamHandler { fun onListen(arguments: Any?, events: EventSink?); fun onCancel(arguments: Any?) }
 fun setStreamHandler(handler: StreamHandler) {}
}
