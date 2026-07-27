package com.winepaster.openSmartBatt

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Host Activity, plus the app's only platform channel.
 *
 * The channel drives [MonitorService] -- start/update/stop the foreground
 * service that keeps the process alive while a pack is connected. Nothing
 * BLE-related crosses it; see MonitorService's header for why.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.winepaster.openSmartBatt/monitor"
    }

    private var channel: MethodChannel? = null

    /** Fires when the service goes away, including via the stop action. */
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            channel?.invokeMethod("onStopRequested", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startMonitor(MonitorService.ACTION_START, call.arguments())
                        result.success(true)
                    }
                    "update" -> {
                        startMonitor(MonitorService.ACTION_UPDATE, call.arguments())
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this@MainActivity, MonitorService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        val filter = IntentFilter(MonitorService.ACTION_STOP_REQUESTED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(stopReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(stopReceiver, filter)
        }
    }

    private fun startMonitor(action: String, args: Map<String, String>?) {
        val intent = Intent(this, MonitorService::class.java).setAction(action).apply {
            putExtra(MonitorService.EXTRA_TITLE, args?.get("title").orEmpty())
            putExtra(MonitorService.EXTRA_BODY, args?.get("body").orEmpty())
            putExtra(MonitorService.EXTRA_STOP_LABEL, args?.get("stopLabel").orEmpty())
            putExtra(MonitorService.EXTRA_CHANNEL_NAME, args?.get("channelName").orEmpty())
            putExtra(MonitorService.EXTRA_CHANNEL_DESC, args?.get("channelDescription").orEmpty())
        }
        // startForegroundService is required from O onwards; the service then
        // has a few seconds to call startForeground(), which it does in
        // onStartCommand before returning.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(stopReceiver) }
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }
}
