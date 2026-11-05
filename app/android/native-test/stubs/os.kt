@file:Suppress("UNUSED_PARAMETER")
package android.os
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
object Build { object VERSION { var SDK_INT=35 } }
object SystemClock { fun elapsedRealtime():Long=System.nanoTime()/1_000_000 }
class ParcelFileDescriptor { companion object {val next=AtomicInteger(100)};val fd=next.incrementAndGet();@Volatile var closed=false;fun close(){closed=true} }
class Looper { companion object {private val main=Looper();fun getMainLooper()=main} }
class Handler(looper:Looper) {
 companion object {val queue=ConcurrentLinkedQueue<Runnable>();val delayed=ConcurrentLinkedQueue<Runnable>();fun fireDelayed(){while(true){val r=delayed.poll()?:return;r.run()}}; fun drain(){while(true){val task=queue.poll()?:return;task.run()}} }
 fun post(r:Runnable):Boolean {queue.add(r);return true}
 fun postDelayed(r:Runnable,delay:Long):Boolean {delayed.add(r);return true}
 fun removeCallbacks(r:Runnable){queue.remove(r);delayed.remove(r)}
}

class Bundle
