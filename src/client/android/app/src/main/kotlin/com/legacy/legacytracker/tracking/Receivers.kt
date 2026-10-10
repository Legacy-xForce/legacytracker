package com.legacy.legacytracker.tracking

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.legacy.legacytracker.updates.AppUpdater
import com.legacy.legacytracker.updates.UpdateWorker

/**
 * Target of the engine's PendingIntents: geofence exits, activity
 * transitions, low-power location results and the trip backstop alarm. These
 * arrive even when the app process is not running — Android starts it just
 * for the event — which is what lets tracking survive the app being closed.
 */
class TrackingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val engine = TrackingEngine.get(context)
        val pending = goAsync()
        engine.post(
            {
                when (intent.action) {
                    ACTION_GEOFENCE -> engine.onGeofenceIntent(intent)
                    ACTION_ACTIVITY -> engine.onActivityIntent(intent)
                    ACTION_LOW_POWER -> engine.onLowPowerIntent(intent)
                    ACTION_ALARM -> engine.onAlarm()
                }
            },
            { pending.finish() },
        )
    }

    companion object {
        const val ACTION_GEOFENCE = "com.legacy.legacytracker.tracking.GEOFENCE"
        const val ACTION_ACTIVITY = "com.legacy.legacytracker.tracking.ACTIVITY"
        const val ACTION_LOW_POWER = "com.legacy.legacytracker.tracking.LOW_POWER"
        const val ACTION_ALARM = "com.legacy.legacytracker.tracking.ALARM"
    }
}

/** Geofences and activity registrations do not survive reboots; re-arm them. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            AppUpdater.get(context).onPackageReplaced()
        }
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            -> {
                val engine = TrackingEngine.get(context)
                val pending = goAsync()
                engine.post({ engine.onBoot() }, { pending.finish() })
            }
        }
    }
}

/**
 * Receives the server's tracking commands (FCM data messages carrying
 * `lt_cmd`) natively, through the same broadcast firebase_messaging listens
 * to — so a "someone opened the map" wake-up needs no Flutter engine and
 * responds within the brief background-start window a high-priority message
 * grants.
 */
class PushCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val command = intent.getStringExtra("lt_cmd") ?: return
        if (command == "update") {
            // A new release is out; see updates/AppUpdater.kt.
            UpdateWorker.runNow(context, "release announced")
            return
        }
        val ttl = intent.getStringExtra("lt_ttl")?.toIntOrNull() ?: 0
        val engine = TrackingEngine.get(context)
        val pending = goAsync()
        engine.post({ engine.onCommand(command, ttl) }, { pending.finish() })
    }
}
