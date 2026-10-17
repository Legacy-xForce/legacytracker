package com.legacy.legacytracker.tracking

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.legacy.legacytracker.R

/**
 * Tells the user that background sharing stopped because the server rejected
 * the upload credentials (revoked, or a copied token was detected). Only the
 * app can fix that — it re-registers with the user's login when opened — so
 * without this the marker would go stale with no sign on the phone.
 */
object SharingPausedNotice {
    private const val CHANNEL_ID = "lt_sharing"
    private const val NOTIFICATION_ID = 4202

    @SuppressLint("MissingPermission") // checked via areNotificationsEnabled
    fun show(context: Context) {
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Location sharing", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                context,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_tracking)
            .setContentTitle("Location sharing paused")
            .setContentText("Open Legacy Tracker to resume sharing your location.")
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            // Notification permission revoked meanwhile; the app still re-registers when opened.
        }
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }
}
