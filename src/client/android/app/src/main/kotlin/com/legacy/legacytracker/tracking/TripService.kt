package com.legacy.legacytracker.tracking

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.legacy.legacytracker.R

/**
 * Keeps the process in the foreground while a trip (or a one-off ping) needs
 * the GPS. It holds no logic of its own — [TrackingEngine] runs the session.
 *
 * Android only grants continuous background GPS to a foreground service, and
 * a foreground service must show a notification. This one exists only while
 * moving, uses a minimum-importance channel (no status-bar icon, no sound,
 * collapsed in the shade), and is deferred so a quick ping usually finishes
 * before it is ever shown. On Android 13+ it is not shown at all unless the
 * user granted notifications; on 14+ it can be swiped away without stopping
 * the trip.
 */
class TripService : Service() {

    enum class StartResult { STARTED, NOT_ALLOWED, NO_PERMISSION, FAILED }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_TRIP
        val reason = intent?.getStringExtra(EXTRA_REASON) ?: "restarted by the system"
        val engine = TrackingEngine.get(this)
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(this, ping = action == ACTION_PING),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            engine.post { engine.onTripServiceStartFailed(e) }
            stopSelf()
            return START_NOT_STICKY
        }
        val service = this
        engine.post { engine.attachTripService(service, action, reason) }
        return START_STICKY
    }

    override fun onDestroy() {
        val service = this
        val engine = TrackingEngine.get(this)
        engine.post { engine.detachTripService(service) }
        super.onDestroy()
    }

    @SuppressLint("MissingPermission")
    fun showNotification(ping: Boolean) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            manager.notify(NOTIFICATION_ID, buildNotification(this, ping))
        } catch (e: SecurityException) {
            // Notifications not permitted: the service runs without one.
        }
    }

    companion object {
        const val ACTION_TRIP = "com.legacy.legacytracker.tracking.TRIP"
        const val ACTION_PING = "com.legacy.legacytracker.tracking.PING"
        private const val EXTRA_REASON = "reason"
        private const val NOTIFICATION_ID = 7420
        private const val CHANNEL_ID = "lt_trips"

        fun start(context: Context, action: String, reason: String): StartResult {
            val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
            if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) {
                return StartResult.NO_PERMISSION
            }
            val intent = Intent(context, TripService::class.java)
                .setAction(action)
                .putExtra(EXTRA_REASON, reason)
            return try {
                ContextCompat.startForegroundService(context, intent)
                StartResult.STARTED
            } catch (e: IllegalStateException) {
                // ForegroundServiceStartNotAllowedException (Android 12+): no
                // background-start exemption applies right now.
                StartResult.NOT_ALLOWED
            } catch (e: SecurityException) {
                StartResult.NO_PERMISSION
            } catch (e: Exception) {
                StartResult.FAILED
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TripService::class.java))
        }

        private fun buildNotification(context: Context, ping: Boolean): Notification {
            ensureChannel(context)
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val contentIntent = launch?.let {
                PendingIntent.getActivity(
                    context,
                    0,
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_tracking)
                .setContentTitle(if (ping) "Updating your location" else "Trip in progress")
                .setContentText(
                    if (ping) "Sharing where you are right now" else "Recording this trip for your group",
                )
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setSilent(true)
                .setShowWhen(false)
                .setLocalOnly(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_DEFERRED)
                .build()
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(CHANNEL_ID, "Trip recording", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Shown only while a trip is being recorded."
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        }
    }
}
