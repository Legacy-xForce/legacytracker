package com.legacy.legacytracker.tracking

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
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
 * Delivers the queue once a network is available — the offline path. Runs
 * even if the app process died after the failed attempt.
 */
class UploadWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val engine = TrackingEngine.get(applicationContext)
        val outcome = engine.uploader.uploadAll()
        engine.post { engine.log("upload", "Background upload: ${outcome.javaClass.simpleName}") }
        return when (outcome) {
            is Uploader.Result.Failed, Uploader.Result.Offline -> Result.retry()
            else -> Result.success()
        }
    }

    companion object {
        private const val NAME = "lt_upload"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequest.Builder(UploadWorker::class.java)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(NAME, ExistingWorkPolicy.KEEP, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}

/**
 * Half-hourly safety net: re-arms the stationary triggers (they can be lost
 * when location is toggled or Play services restarts), resumes a trip whose
 * process was killed, sends a liveness heartbeat while parked, and flushes.
 */
class WatchdogWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        TrackingEngine.get(applicationContext).runWatchdog()
        return Result.success()
    }

    companion object {
        private const val NAME = "lt_watchdog"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequest.Builder(
                WatchdogWorker::class.java,
                Tuning.WATCHDOG_INTERVAL_MINUTES,
                TimeUnit.MINUTES,
            ).build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}
