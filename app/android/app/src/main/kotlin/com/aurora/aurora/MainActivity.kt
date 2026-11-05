package com.aurora.aurora

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.net.Uri
import com.aurora.vpn.AuroraTailnetChannel
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.aurora.vpn.AuroraState
import com.aurora.vpn.AuroraVpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Aurora platform channels:
 *  - MethodChannel `aurora/method`: prepare / start / stop / status / queryStats
 *  - EventChannel  `aurora/events`: status changes (from AuroraState)
 */
class MainActivity : FlutterActivity() {

    private val methodChannelName = "aurora/method"
    private val eventChannelName = "aurora/events"
    private val statsChannelName = "aurora/stats"
    private val groupsChannelName = "aurora/groups"
    private val vpnRequestCode = 1001

    @Volatile private var tailnetOwner: Any? = null
    private var tailnetChannel: MethodChannel? = null
    private var foreground = false

    private var pendingPrepareResult: MethodChannel.Result? = null
    private var statusSink: EventChannel.EventSink? = null
    private val statusListener: (String) -> Unit = { value ->
        runOnUiThread { statusSink?.success(value) }
    }
    private var statsSink: EventChannel.EventSink? = null
    private val statsListener: (Map<String, Any?>) -> Unit = { value ->
        runOnUiThread { statsSink?.success(value) }
    }
    private var groupsSink: EventChannel.EventSink? = null
    private val groupsListener: (List<Map<String, Any?>>) -> Unit = { value ->
        runOnUiThread { groupsSink?.success(value) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+: notifications need runtime consent for the foreground-service notice.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2002)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val owner = Any().also { tailnetOwner = it }
        val tailnet = AuroraTailnetChannel(applicationContext.noBackupFilesDir,
            currentActivity = { tailnetOwner === owner },
            foreground = { foreground && !isDestroyed && !isFinishing && hasWindowFocus() },
            startService = { config, generation, node ->
                val intent = Intent(this, AuroraVpnService::class.java).apply {
                    action = AuroraVpnService.ACTION_START
                    putExtra(AuroraVpnService.EXTRA_CONFIG, config)
                    putExtra(AuroraVpnService.EXTRA_TAILNET_GENERATION, generation)
                    putExtra(AuroraVpnService.EXTRA_TAILNET_NODE, node)
                }
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
            },
            launch = { url -> startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) })
        tailnetChannel = MethodChannel(messenger, "aurora/tailnet").also { channel ->
            channel.setMethodCallHandler { call, result ->
                tailnet.handle(call.method, call.arguments, object : AuroraTailnetChannel.Result {
                    override fun success(value: Any?) { result.success(value) }
                    override fun error(code: String) { result.error(code, "Tailnet operation failed", null) }
                })
            }
        }

        MethodChannel(messenger, methodChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "sessionSnapshot" -> result.success(AuroraVpnService.sessionSnapshot())
                "reloadCurrentSession" -> {
                    val sessionId = call.argument<String>("sessionId")
                    if (sessionId.isNullOrBlank()) result.success("unavailable")
                    else AuroraVpnService.reloadCurrentSession(sessionId) { value ->
                        runOnUiThread { result.success(value) }
                    }
                }
                "prepare" -> {
                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        pendingPrepareResult = result
                        startActivityForResult(intent, vpnRequestCode)
                    } else {
                        result.success(true)
                    }
                }
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("no_config", "config is required", null)
                    } else {
                        val intent = Intent(this, AuroraVpnService::class.java).apply {
                            action = AuroraVpnService.ACTION_START
                            putExtra(AuroraVpnService.EXTRA_CONFIG, config)
                        }
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent)
                        else startService(intent)
                        result.success(null)
                    }
                }
                "stop" -> {
                    startService(
                        Intent(this, AuroraVpnService::class.java)
                            .apply { action = AuroraVpnService.ACTION_STOP }
                    )
                    result.success(null)
                }
                "status" -> result.success(AuroraState.status)
                "openVpnSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_VPN_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "queryStats" -> result.success(AuroraState.stats)
                "selectOutbound" -> {
                    val group = call.argument<String>("group")
                    val tag = call.argument<String>("tag")
                    if (group.isNullOrBlank() || tag.isNullOrBlank()) {
                        result.error("invalid_selection", "selector arguments are required", null)
                    } else {
                        val commandClient = AuroraState.commandClient
                        if (commandClient == null) {
                            // A fresh config's selector starts fail-closed. The
                            // Dart bridge still requires group-stream readback.
                            if (tag == "fail-closed") result.success(null)
                            else result.error("command_unavailable", "selector unavailable", null)
                        } else {
                            try {
                                commandClient.selectOutbound(group, tag)
                                result.success(null)
                            } catch (_: Exception) {
                                result.error("selection_failed", "selector command failed", null)
                            }
                        }
                    }
                }
                "urlTest" -> {
                    AuroraState.commandClient?.urlTest(call.argument<String>("group") ?: "proxy")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, eventChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statusSink = events
                    // re-listen must not double-register (the listener list has no dedup)
                    AuroraState.removeListener(statusListener)
                    AuroraState.addListener(statusListener)
                }

                override fun onCancel(arguments: Any?) {
                    AuroraState.removeListener(statusListener)
                    statusSink = null
                }
            }
        )

        EventChannel(messenger, statsChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statsSink = events
                    AuroraState.removeStatsListener(statsListener)
                    AuroraState.addStatsListener(statsListener)
                }

                override fun onCancel(arguments: Any?) {
                    AuroraState.removeStatsListener(statsListener)
                    statsSink = null
                }
            }
        )

        EventChannel(messenger, groupsChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    groupsSink = events
                    AuroraState.removeGroupsListener(groupsListener)
                    AuroraState.addGroupsListener(groupsListener)
                }

                override fun onCancel(arguments: Any?) {
                    AuroraState.removeGroupsListener(groupsListener)
                    groupsSink = null
                }
            }
        )
    }

    override fun onResume() { super.onResume(); foreground = true }
    override fun onPause() { foreground = false; super.onPause() }
    override fun onDestroy() {
        foreground = false
        tailnetOwner = null
        tailnetChannel?.setMethodCallHandler(null)
        tailnetChannel = null
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == vpnRequestCode) {
            pendingPrepareResult?.success(resultCode == Activity.RESULT_OK)
            pendingPrepareResult = null
        }
    }
}
