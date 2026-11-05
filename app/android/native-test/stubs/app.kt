@file:Suppress("UNUSED_PARAMETER")
package android.app
import android.content.Context
import android.os.Build
class Notification(val channelId: String? = null) {
 class Builder {
  private val channelId: String?
  constructor(c: Context) { channelId = null }
  constructor(c: Context, id: String) {
   if (Build.VERSION.SDK_INT < 26) throw NoSuchMethodError("Notification.Builder(Context,String) requires API 26")
   channelId = id
  }
  fun setContentTitle(s:String)=this
  fun setContentText(s:String)=this
  fun setSmallIcon(i:Int)=this
  fun setOngoing(b:Boolean)=this
  fun build()=Notification(channelId)
 }
}
class NotificationChannel(id:String,name:String,importance:Int)
class NotificationManager { companion object {const val IMPORTANCE_LOW=1};fun getNotificationChannel(id:String):NotificationChannel?=null;fun createNotificationChannel(c:NotificationChannel){};fun notify(id:Int,n:Notification){} }
open class Activity : Context() {
 companion object { const val RESULT_OK = -1 }
 var isFinishing = false; var isDestroyed = false; var focused = true
 val serviceStarts = java.util.concurrent.CopyOnWriteArrayList<android.content.Intent>()
 val activityStarts = java.util.concurrent.CopyOnWriteArrayList<android.content.Intent>()
 fun hasWindowFocus() = focused
 fun runOnUiThread(action: Runnable) { android.os.Handler(android.os.Looper.getMainLooper()).post(action) }
 fun checkSelfPermission(permission: String) = 0
 fun requestPermissions(permissions: Array<String>, request: Int) {}
 open fun onCreate(savedInstanceState: android.os.Bundle?) {}
 open fun onResume() {}; open fun onPause() {}; open fun onDestroy() { isDestroyed = true }
 open fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {}
 fun startActivityForResult(intent: android.content.Intent, request: Int) { activityStarts.add(intent) }
 fun startActivity(intent: android.content.Intent) { activityStarts.add(intent) }
 fun startService(intent: android.content.Intent) { serviceStarts.add(intent) }
 fun startForegroundService(intent: android.content.Intent) { serviceStarts.add(intent) }
}
