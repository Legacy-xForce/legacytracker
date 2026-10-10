package com.legacy.legacytracker.updates

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Checks for, downloads and — when the moment is right — installs updates in
 * the background: every few hours, when the server announces a release over
 * FCM, and a few minutes after the app leaves the screen with one waiting.
 */
class UpdateWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val updater = AppUpdater.get(applicationContext)
        if (!updater.automatic) return Result.success()
        val trigger = inputData.getString(KEY_TRIGGER) ?: "periodic check"
        return try {
            val release = updater.check()
            if (release != null && !updater.hasFailed(release)) {
                updater.download(release)
                updater.installIfIdle(trigger)
            }
            Result.success()
        } catch (e: Exception) {
            updater.recordError(e)
            if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.success()
        }
    }

    companion object {
        private const val PERIODIC = "lt_update_periodic"
        private const val NOW = "lt_update_now"
        private const val IDLE = "lt_update_idle"
        private const val KEY_TRIGGER = "trigger"
        private const val MAX_ATTEMPTS = 3
        private const val INTERVAL_HOURS = 6L
        /** Long enough that a quick trip to another app doesn't close this one. */
        private const val IDLE_DELAY_MINUTES = 3L

        private val online = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        fun schedule(context: Context) {
            val request = PeriodicWorkRequest.Builder(UpdateWorker::class.java, INTERVAL_HOURS, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .setRequiresBatteryNotLow(true)
                        .build(),
                )
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        /** An immediate check, e.g. the server announced a release. */
        fun runNow(context: Context, trigger: String) {
            WorkManager.getInstance(context)
                .enqueueUniqueWork(NOW, ExistingWorkPolicy.KEEP, oneTime(trigger, delayMinutes = 0))
        }

        /** Installs a waiting update once the app has stayed in the background a while. */
        fun installWhenIdle(context: Context) {
            WorkManager.getInstance(context)
                .enqueueUniqueWork(IDLE, ExistingWorkPolicy.REPLACE, oneTime("app in background", IDLE_DELAY_MINUTES))
        }

        private fun oneTime(trigger: String, delayMinutes: Long) =
            OneTimeWorkRequest.Builder(UpdateWorker::class.java)
                .setInputData(Data.Builder().putString(KEY_TRIGGER, trigger).build())
                .setInitialDelay(delayMinutes, TimeUnit.MINUTES)
                .setConstraints(online)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
                .build()
    }
}
