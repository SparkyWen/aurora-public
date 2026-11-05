@file:Suppress("UNUSED_PARAMETER")
package android.util
object Log {
 var hook:((String)->Unit)?=null
 val records=java.util.concurrent.CopyOnWriteArrayList<String>()
 private fun record(m:String,e:Throwable?=null):Int {records.add(m+(e?.message?:""));return 0}
 fun i(t:String,m:String):Int {hook?.invoke(m);return record(m)}
 fun d(t:String,m:String):Int=record(m)
 fun w(t:String,m:String,e:Throwable?=null):Int=record(m,e)
 fun e(t:String,m:String,e:Throwable?=null):Int=record(m,e)
}
