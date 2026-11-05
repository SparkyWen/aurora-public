@file:Suppress("UNUSED_PARAMETER")
package android.content
import android.net.ConnectivityManager
import android.app.NotificationManager
import java.io.File
open class Context {
 companion object { const val CONNECTIVITY_SERVICE="connectivity" }
 val connectivity=ConnectivityManager()
 val notifications=NotificationManager()
 val filesDir=File(System.getProperty("java.io.tmpdir"))
 val cacheDir=filesDir
 var noBackupFilesDir=File(filesDir,"aurora-native-unused-no-backup")
 val applicationContext: Context get()=this
 fun getSystemService(name:String):Any=connectivity
 fun <T> getSystemService(type:Class<T>):T=type.cast(notifications)
}
class Intent {
 companion object { const val ACTION_VIEW = "android.intent.action.VIEW"; const val FLAG_ACTIVITY_NEW_TASK = 1 }
 constructor()
 constructor(context: Context, target: Class<*>)
 constructor(action: String) { this.action = action }
 constructor(action: String, uri: android.net.Uri) { this.action = action; data = uri }
 var data: android.net.Uri? = null
 fun addFlags(flags: Int) = this
 var action:String?=null; private val extras=mutableMapOf<String,Any>()
 fun putExtra(key:String,value:String):Intent {extras[key]=value;return this}
 fun putExtra(key:String,value:Long):Intent {extras[key]=value;return this}
 fun getStringExtra(key:String):String?=extras[key] as? String
 fun getLongExtra(key:String,default:Long):Long=extras[key] as? Long ?: default
 fun hasExtra(key:String)=extras.containsKey(key)
}
