package com.winepaster.openSmartBatt

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the app's process at foreground importance while a pack is connected.
 *
 * WHAT THIS SERVICE DOES NOT DO: touch Bluetooth. All BLE work stays in Dart on
 * the main engine -- flutter_blue_plus binds its platform channels to that
 * engine, so a second isolate could not share the GATT connection anyway. The
 * only job here is to stop the OS from freezing the process.
 *
 * Why that is sufficient: with the screen off the Activity goes invisible, the
 * process drops to cached importance, and Doze / App Standby freeze it. The
 * 1 Hz keep-alive Timer stops firing and in-flight GATT writes hang, while the
 * link stays nominally `ready` -- the 828 -> 248 -> 0 -> 1666 -> 832 RX/min
 * shape recorded in test/keepalive_stall_test.dart. A foreground service raises
 * the process back out of that state and the existing Dart loop just keeps
 * running, unchanged.
 *
 * Every user-visible string arrives from Dart rather than res/values. The app
 * has an in-app language override (AppSettings.lang) that is independent of the
 * device locale, so resource qualifiers would disagree with the rest of the UI.
 *
 * See docs/design/0008 (pro repo) for the full rationale.
 */
class MonitorService : Service() {

    companion object {
        const val ACTION_START = "com.winepaster.openSmartBatt.action.START"
        const val ACTION_UPDATE = "com.winepaster.openSmartBatt.action.UPDATE"
        const val ACTION_STOP = "com.winepaster.openSmartBatt.action.STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_STOP_LABEL = "stopLabel"
        const val EXTRA_CHANNEL_NAME = "channelName"
        const val EXTRA_CHANNEL_DESC = "channelDescription"

        private const val CHANNEL_ID = "osb_monitor"
        private const val NOTIFICATION_ID = 1001

        /**
         * Broadcast out when the user taps the notification's stop action, so
         * Dart can tear the BLE link down rather than leaving it orphaned.
         */
        const val ACTION_STOP_REQUESTED =
            "com.winepaster.openSmartBatt.action.STOP_REQUESTED"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForegroundCompat()
                stopSelf()
            }
            ACTION_START, ACTION_UPDATE -> {
                startForegroundCompat(buildNotification(intent))
            }
            else -> {
                // Restarted by the system with a null intent, or an unknown
                // action. There is no BLE connection to resume in that state
                // (see 0008 non-goals), so do not linger as a foreground
                // service showing a notification about nothing.
                stopSelf()
            }
        }
        // Deliberately NOT sticky: if the system kills us, the Dart side and its
        // GATT link are gone too, so a bare service restart would show a
        // "monitoring" notification while monitoring nothing.
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+ requires the type at startForeground() time, and it
            // must match the manifest's android:foregroundServiceType.
            //
            // CONNECTED_DEVICE, never DATA_SYNC: per Android's foreground
            // service timeout docs the 6-hours-per-24 cap applies only to
            // dataSync and mediaProcessing. connectedDevice has no time limit,
            // which is what lets a long ride or an overnight parked watch keep
            // running. Do not "simplify" this to dataSync.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    private fun buildNotification(intent: Intent): Notification {
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val body = intent.getStringExtra(EXTRA_BODY).orEmpty()
        val stopLabel = intent.getStringExtra(EXTRA_STOP_LABEL).orEmpty()

        ensureChannel(intent)

        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // Routed through the service (not straight to Dart) so the tap works
        // even when the Activity is gone: the service stops itself and
        // broadcasts, and Dart drops the link if it is still alive to hear it.
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, MonitorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setShowWhen(false)
            // LOW: this is a status readout, not an alert. It must never buzz
            // or make a sound, least of all once per update.
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)

        if (stopLabel.isNotEmpty()) {
            builder.addAction(0, stopLabel, stopIntent)
        }
        return builder.build()
    }

    private fun ensureChannel(intent: Intent) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val name = intent.getStringExtra(EXTRA_CHANNEL_NAME).orEmpty()
        if (name.isEmpty()) return
        // Re-creating with the same id updates name/description in place, which
        // is how the channel follows an in-app language change. (Importance is
        // immutable after creation -- that is fine, LOW is what we always want.)
        val channel = NotificationChannel(
            CHANNEL_ID,
            name,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = intent.getStringExtra(EXTRA_CHANNEL_DESC).orEmpty()
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    override fun onDestroy() {
        // Tell Dart the watch ended, whichever way we got here (notification
        // action, or the system reclaiming us).
        sendBroadcast(Intent(ACTION_STOP_REQUESTED).setPackage(packageName))
        super.onDestroy()
    }
}
