# gomobile / libbox are called from native via JNI by exact class+method name, and
# our PlatformInterface / CommandClientHandler impls are invoked the same way.
# R8 must not rename/strip them, or the tunnel comes up but traffic never egresses.
-keep class go.** { *; }
-keep class io.nekohasekai.libbox.** { *; }
-keep class com.aurora.vpn.** { *; }
-keep class * implements io.nekohasekai.libbox.PlatformInterface { *; }
-keep class * implements io.nekohasekai.libbox.CommandServerHandler { *; }
-keep class * implements io.nekohasekai.libbox.CommandClientHandler { *; }
-dontwarn go.**
-dontwarn io.nekohasekai.libbox.**
