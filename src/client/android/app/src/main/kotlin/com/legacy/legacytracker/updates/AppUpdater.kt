package com.legacy.legacytracker.updates

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.pm.PackageInfoCompat
import com.legacy.legacytracker.MainActivity
import com.legacy.legacytracker.tracking.EngineState
import com.legacy.legacytracker.tracking.TrackingMode
import com.legacy.legacytracker.tracking.TrackingStore
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Self-update for builds distributed outside the Play Store.
 *
 * The server says which release is current (`GET /api/v1/app/android/latest`,
 * backed by GitHub releases). A newer APK is downloaded, checked against the
 * published SHA-256 and handed to PackageInstaller. Since Android 12 an app
 * may update itself without any prompt once the user has let it install apps
 * ("Install unknown apps"); otherwise Android asks for one confirmation tap,
 * raised from the app or from a notification.
 *
 * Android refuses an update not signed with this app's key, so a compromised
 * server or download can at worst withhold updates, never replace the app.
 *
 * Installing kills the running process, so background installs wait until
 * nobody is looking at the app and no trip is being recorded. BootReceiver
 * re-arms tracking afterwards (MY_PACKAGE_REPLACED).
 */
class AppUpdater private constructor(context: Context) {

    /** A release newer than the installed build, as the server described it. */
    class Release(
        val versionCode: Long,
        val versionName: String,
        val apkUrl: String,
        val sha256: String,
        val size: Long,
        val notes: String,
        /** Short commit hash, only on nightly builds. */
        val commit: String? = null,
        /** Builds older than this must update before they can be used (0: none). */
        val minSupportedCode: Long = 0,
    ) {
        /** Stable builds are keyed by version code, nightlies by commit: two
         * nightlies can share a version code but are different installs. */
        val id: String get() = commit ?: "v$versionCode"
    }

    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("lt_updates", Context.MODE_PRIVATE)
    private val dir = File(app.noBackupFilesDir, "updates")
    /** Serialises downloads and installs between workers and the UI. */
    private val installLock = Any()

    /** For work started from the UI and the update notification. */
    val executor: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "lt-update") }

    /** Called on any thread whenever [status] may have changed. */
    @Volatile
    var listener: (() -> Unit)? = null

    @Volatile
    private var progress: Double? = null

    private val packageInfo = app.packageManager.getPackageInfo(app.packageName, 0)
    val installedVersionCode: Long = PackageInfoCompat.getLongVersionCode(packageInfo)
    private val installedVersionName: String = packageInfo.versionName ?: ""

    /** Whether updates happen on their own. `flutter run` builds only update when asked. */
    val automatic = (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0

    // ── Lifecycle ───────────────────────────────────────────────────────────

    /** Called by Dart at every app start, and again when the channel changes. */
    fun configure(baseUrl: String, channel: String = "stable") {
        val selected = if (channel == "nightly") "nightly" else "stable"
        val previous = prefs.getString(K_CHANNEL, "stable")
        prefs.edit()
            .putString(K_BASE_URL, baseUrl.trimEnd('/'))
            .putString(K_CHANNEL, selected)
            .apply()
        // Never let a cached release (or its staged APK) jump between channels.
        if (previous != selected) resetForChannelSwitch()
        cleanUp()
        if (!automatic) return
        UpdateWorker.schedule(app)
        if (System.currentTimeMillis() - prefs.getLong(K_LAST_CHECK, 0L) > Tuning.CHECK_ON_START_AFTER_MS) {
            UpdateWorker.runNow(app, "app opened")
        }
    }

    private fun currentChannel(): String =
        if (prefs.getString(K_CHANNEL, null) == "nightly") "nightly" else "stable"

    /** MainActivity left the screen: a waiting update can go in shortly. */
    fun onAppBackgrounded() {
        if (automatic && available() != null) UpdateWorker.installWhenIdle(app)
    }

    /** The update notification opened the app: install with Android's confirmation. */
    fun onLaunchIntent(intent: Intent?) {
        // A stale notification: the update went in meanwhile.
        if (intent?.action != ACTION_INSTALL || available() == null) return
        executor.execute {
            try {
                install("tapped the update notification")
            } catch (e: Exception) {
                recordError(e)
            }
        }
    }

    /** First start of a new version (MY_PACKAGE_REPLACED). */
    fun onPackageReplaced() {
        log("App updated to $installedVersionName ($installedVersionCode)")
        cleanUp()
    }

    // ── Check, download, install ────────────────────────────────────────────

    /**
     * Asks the server for the current release and remembers it when it is
     * newer than this build. Blocking; throws when the server can't answer.
     */
    fun check(): Release? {
        val release = try {
            fetchLatest()
        } catch (e: Exception) {
            throw IOException("Update check failed: ${e.message ?: e.javaClass.simpleName}", e)
        }
        // A nightly is identified by its commit, not just its version code:
        // every build from main has the pubspec code, which often equals the
        // installed one. Stable keeps the stricter code comparison.
        val installedCommit = prefs.getString(K_INSTALLED_COMMIT, null)
        val newer = release?.takeIf {
            it.versionCode > installedVersionCode ||
                (it.commit != null && it.commit != installedCommit)
        }
        val previous = prefs.getLong(K_AVAILABLE_CODE, 0L)
        saveAvailable(newer)
        prefs.edit()
            .putLong(K_LAST_CHECK, System.currentTimeMillis())
            .putLong(K_MIN_SUPPORTED, release?.minSupportedCode ?: 0L)
            .remove(K_LAST_ERROR)
            .apply()
        if (newer != null && newer.versionCode != previous) {
            log("Update available: ${newer.versionName} (${newer.versionCode})")
        }
        notifyChanged()
        return newer
    }

    private fun fetchLatest(): Release? {
        val baseUrl = prefs.getString(K_BASE_URL, null)
            ?: EngineState(app).baseUrl
            ?: throw IOException("server address not configured yet")
        val path = if (currentChannel() == "nightly")
            "/api/v1/app/android/nightly" else "/api/v1/app/android/latest"
        val connection = URL("$baseUrl$path").openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            return when (val code = connection.responseCode) {
                200 -> parseRelease(connection.inputStream.bufferedReader().use { it.readText() })
                204 -> null
                else -> throw IOException("HTTP $code")
            }
        } finally {
            connection.disconnect()
        }
    }

    /** The newer release found by the last [check], if any. */
    fun available(): Release? {
        val code = prefs.getLong(K_AVAILABLE_CODE, 0L)
        if (code <= 0L) return null
        val commit = prefs.getString(K_AVAILABLE_COMMIT, null)
        // Stable: the cached code must still be newer than this build. Nightly:
        // a different commit is an update even at the same version code.
        if (commit == null) {
            if (code <= installedVersionCode) return null
        } else if (commit == prefs.getString(K_INSTALLED_COMMIT, null)) {
            return null
        }
        return Release(
            versionCode = code,
            versionName = prefs.getString(K_AVAILABLE_NAME, null) ?: code.toString(),
            apkUrl = prefs.getString(K_AVAILABLE_URL, null) ?: return null,
            sha256 = prefs.getString(K_AVAILABLE_SHA, null) ?: return null,
            size = prefs.getLong(K_AVAILABLE_SIZE, 0L),
            notes = prefs.getString(K_AVAILABLE_NOTES, null) ?: "",
            commit = commit,
        )
    }

    /** Whether installing [release] already failed in a way retrying won't fix. */
    fun hasFailed(release: Release) = prefs.getString(K_FAILED_ID, null) == release.id

    /** Downloads [release] unless already done, verifying size and SHA-256. Blocking. */
    fun download(release: Release): File = synchronized(installLock) {
        val target = apkFile(release)
        if (isDownloaded(release)) return target

        dir.mkdirs()
        dir.listFiles()?.forEach { it.delete() }
        val partial = File(dir, target.name + ".part")
        val digest = MessageDigest.getInstance("SHA-256")
        var received = 0L
        val connection = URL(release.apkUrl).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 60_000
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("HTTP $code")
            var reportedPercent = -1L
            connection.inputStream.use { input ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        received += read
                        if (received > release.size) throw IOException("file is larger than published")
                        output.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        val percent = received * 100 / release.size.coerceAtLeast(1)
                        if (percent != reportedPercent) {
                            reportedPercent = percent
                            setProgress(received.toDouble() / release.size)
                        }
                    }
                }
            }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }
            if (received != release.size || hash != release.sha256) {
                throw IOException("checksum mismatch")
            }
            if (!partial.renameTo(target)) throw IOException("could not store the file")
        } catch (e: Exception) {
            partial.delete()
            throw IOException("Download failed: ${e.message ?: e.javaClass.simpleName}", e)
        } finally {
            connection.disconnect()
            setProgress(null)
        }
        prefs.edit().putString(K_DOWNLOADED_ID, release.id).apply()
        log("Downloaded ${release.versionName} (${release.versionCode})")
        notifyChanged()
        target
    }

    /**
     * Background install of the downloaded update, if now is a good moment:
     * the app is not on screen (installing closes it) and no trip is being
     * recorded (its GPS session would be cut short). Without permission to
     * install silently, posts a "tap to install" notification instead.
     */
    fun installIfIdle(reason: String) {
        if (!automatic) return
        val release = available() ?: return
        if (hasFailed(release) || !isDownloaded(release) || foreground) return
        if (EngineState(app).mode == TrackingMode.MOVING) {
            log("Update to ${release.versionName} waits for the current trip to end")
            return
        }
        if (canInstallSilently()) {
            install(reason)
        } else {
            notifyUpdateReady(release)
        }
    }

    /**
     * Downloads (if needed) and installs the available update now. On
     * Android 12+, with permission to install apps, no prompt is shown and
     * the app closes; otherwise Android asks the user first. Blocking.
     */
    fun install(reason: String) = synchronized(installLock) {
        val release = available() ?: throw IllegalStateException("no update available")
        val file = download(release)
        val installer = app.packageManager.packageInstaller
        // A previous attempt still waiting for the user would hold a second copy.
        for (session in installer.mySessions) {
            runCatching { installer.abandonSession(session.sessionId) }
        }

        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(app.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val intent = Intent(app, UpdateInstallReceiver::class.java)
                    .setAction(UpdateInstallReceiver.ACTION_STATUS)
                    .putExtra(UpdateInstallReceiver.EXTRA_VERSION_CODE, release.versionCode)
                // Mutable: the installer adds the status extras.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
                val callback = PendingIntent.getBroadcast(app, sessionId, intent, flags)
                log("Installing ${release.versionName} (${release.versionCode}) — $reason")
                session.commit(callback.intentSender)
            }
        } catch (e: Exception) {
            runCatching { installer.abandonSession(sessionId) }
            throw e
        }
    }

    /** Result of a commit, from UpdateInstallReceiver. */
    fun onInstallStatus(status: Int, versionCode: Long, message: String?, confirm: Intent?) {
        val release = available()?.takeIf { it.versionCode == versionCode }
        val version = release?.let { "${it.versionName} ($versionCode)" } ?: versionCode.toString()
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                if (confirm != null && foreground) {
                    app.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } else {
                    // Activities can't be started from the background; the
                    // notification reopens the app, which asks again.
                    available()?.let { notifyUpdateReady(it) }
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // This is the nightly now running: remember it so the next
                // check can tell a fresh build from the one already installed.
                if (release?.commit != null) {
                    prefs.edit().putString(K_INSTALLED_COMMIT, release.commit).apply()
                }
                cleanUp()
            }
            PackageInstaller.STATUS_FAILURE_ABORTED -> log("Update to $version was cancelled")
            PackageInstaller.STATUS_FAILURE_CONFLICT,
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE,
            PackageInstaller.STATUS_FAILURE_INVALID,
            PackageInstaller.STATUS_FAILURE_BLOCKED,
            -> {
                // E.g. signed with a different key: this build will never
                // install, so stop retrying it until a newer one is published.
                val id = release?.id ?: "v$versionCode"
                prefs.edit().putString(K_FAILED_ID, id).apply()
                apkFile(id).delete()
                recordError("Update to $version can't be installed: ${message ?: "status $status"}")
            }
            else -> recordError("Update to $version failed: ${message ?: "status $status"}")
        }
        notifyChanged()
    }

    // ── Status ──────────────────────────────────────────────────────────────

    fun status(): Map<String, Any?> {
        val release = available()
        return mapOf(
            "currentVersionCode" to installedVersionCode,
            "currentVersionName" to installedVersionName,
            "availableVersionCode" to release?.versionCode,
            "minSupportedCode" to prefs.getLong(K_MIN_SUPPORTED, 0L),
            "availableVersionName" to release?.versionName,
            "notes" to release?.notes,
            "downloaded" to (release != null && isDownloaded(release)),
            "failed" to (release != null && hasFailed(release)),
            "progress" to progress,
            "installPermission" to canRequestInstalls(),
            "silentInstall" to canInstallSilently(),
            "automatic" to automatic,
            "lastCheckAt" to prefs.getLong(K_LAST_CHECK, 0L).takeIf { it > 0 },
            "lastError" to prefs.getString(K_LAST_ERROR, null),
            "channel" to currentChannel(),
        )
    }

    fun recordError(error: Exception) =
        recordError(error.message ?: error.javaClass.simpleName)

    private fun recordError(message: String) {
        prefs.edit().putString(K_LAST_ERROR, message).apply()
        log(message)
        notifyChanged()
    }

    /** "Install unknown apps" for this app; before Android 8 a global setting. */
    private fun canRequestInstalls() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || app.packageManager.canRequestPackageInstalls()

    private fun canInstallSilently() =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && canRequestInstalls()

    // ── Helpers ─────────────────────────────────────────────────────────────

    private fun apkFile(release: Release) = File(dir, "legacytracker-${release.id}.apk")

    private fun apkFile(id: String) = File(dir, "legacytracker-$id.apk")

    private fun isDownloaded(release: Release): Boolean =
        prefs.getString(K_DOWNLOADED_ID, null) == release.id &&
            apkFile(release).length() == release.size

    private fun parseRelease(body: String): Release? {
        val json = JSONObject(body)
        // Last line of defence: even a server regression must not make a phone
        // on the stable channel install a nightly build.
        if (json.optString("channel", "") == "nightly" && currentChannel() != "nightly") {
            return null
        }
        return Release(
            versionCode = json.getLong("version_code"),
            versionName = json.getString("version_name"),
            apkUrl = json.getString("apk_url"),
            sha256 = json.getString("sha256").lowercase(),
            size = json.getLong("size"),
            notes = json.optString("notes", ""),
            commit = json.optString("commit", "").takeIf { it.isNotEmpty() },
            minSupportedCode = json.optLong("min_supported_code", 0L),
        )
    }

    private fun saveAvailable(release: Release?) {
        val editor = prefs.edit()
        if (release == null) {
            editor.remove(K_AVAILABLE_CODE).remove(K_AVAILABLE_COMMIT)
        } else {
            editor.putLong(K_AVAILABLE_CODE, release.versionCode)
                .putString(K_AVAILABLE_NAME, release.versionName)
                .putString(K_AVAILABLE_URL, release.apkUrl)
                .putString(K_AVAILABLE_SHA, release.sha256)
                .putLong(K_AVAILABLE_SIZE, release.size)
                .putString(K_AVAILABLE_NOTES, release.notes)
                .putString(K_AVAILABLE_COMMIT, release.commit)
        }
        editor.apply()
    }

    /** Forgets releases and files this build has caught up with. */
    private fun cleanUp() {
        val editor = prefs.edit()
        val installedCommit = prefs.getString(K_INSTALLED_COMMIT, null)
        val availableCommit = prefs.getString(K_AVAILABLE_COMMIT, null)
        val stableAvailableDone =
            availableCommit == null && prefs.getLong(K_AVAILABLE_CODE, 0L) <= installedVersionCode
        val nightlyAvailableDone =
            availableCommit != null && availableCommit == installedCommit
        if (stableAvailableDone || nightlyAvailableDone) {
            editor.remove(K_AVAILABLE_CODE).remove(K_AVAILABLE_COMMIT)
        }
        for (key in listOf(K_DOWNLOADED_ID, K_FAILED_ID)) {
            val id = prefs.getString(key, null) ?: continue
            val done = id.removePrefix("v").toLongOrNull()?.let { it <= installedVersionCode }
                ?: (id == installedCommit)
            if (done) editor.remove(key)
        }
        editor.apply()
        val keep = available()?.let { apkFile(it) }
        dir.listFiles()?.forEach { if (it != keep) it.delete() }
        if (keep == null) NotificationManagerCompat.from(app).cancel(NOTIFICATION_ID)
    }

    /** Switching channels must never install a cached APK from the other one. */
    private fun resetForChannelSwitch() {
        prefs.edit()
            .remove(K_AVAILABLE_CODE).remove(K_AVAILABLE_COMMIT)
            .remove(K_AVAILABLE_NAME).remove(K_AVAILABLE_URL)
            .remove(K_AVAILABLE_SHA).remove(K_AVAILABLE_SIZE).remove(K_AVAILABLE_NOTES)
            .remove(K_DOWNLOADED_ID).remove(K_FAILED_ID)
            .remove(K_LAST_ERROR).remove(K_MIN_SUPPORTED)
            .apply()
        dir.listFiles()?.forEach { it.delete() }
        NotificationManagerCompat.from(app).cancel(NOTIFICATION_ID)
        notifyChanged()
    }

    private fun setProgress(value: Double?) {
        progress = value
        notifyChanged()
    }

    private fun notifyChanged() {
        listener?.invoke()
    }

    @SuppressLint("MissingPermission") // checked via areNotificationsEnabled
    private fun notifyUpdateReady(release: Release) {
        val manager = NotificationManagerCompat.from(app)
        if (!manager.areNotificationsEnabled()) {
            log("Update to ${release.versionName} is ready; notifications are off, so it waits for the app")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "App updates", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val open = Intent(app, MainActivity::class.java)
            .setAction(ACTION_INSTALL)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val contentIntent = PendingIntent.getActivity(
            app,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Update ready")
            .setContentText("Tap to install Legacy Tracker ${release.versionName}")
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            // Notification permission revoked meanwhile; the profile tab still shows it.
        }
    }

    private fun log(message: String) {
        Log.i(TAG, message)
        runCatching { TrackingStore.get(app).log("update", message) }
    }

    private object Tuning {
        /** Opening the app checks at most this often; workers cover the rest. */
        const val CHECK_ON_START_AFTER_MS = 60 * 60_000L
    }

    companion object {
        private const val TAG = "AppUpdater"
        const val ACTION_INSTALL = "com.legacy.legacytracker.updates.INSTALL"
        private const val CHANNEL_ID = "lt_updates"
        private const val NOTIFICATION_ID = 4201

        private const val K_BASE_URL = "base_url"
        private const val K_CHANNEL = "channel"
        private const val K_LAST_CHECK = "last_check"
        private const val K_LAST_ERROR = "last_error"
        private const val K_AVAILABLE_CODE = "available_code"
        private const val K_MIN_SUPPORTED = "min_supported_code"
        private const val K_AVAILABLE_NAME = "available_name"
        private const val K_AVAILABLE_URL = "available_url"
        private const val K_AVAILABLE_SHA = "available_sha256"
        private const val K_AVAILABLE_SIZE = "available_size"
        private const val K_AVAILABLE_NOTES = "available_notes"
        private const val K_AVAILABLE_COMMIT = "available_commit"
        private const val K_DOWNLOADED_ID = "downloaded_id"
        private const val K_FAILED_ID = "failed_id"
        /** Commit of the nightly currently installed (stable installs leave it alone). */
        private const val K_INSTALLED_COMMIT = "installed_commit"

        /** Whether MainActivity is on screen (set by it). Process-scoped. */
        @Volatile
        var foreground = false

        @Volatile
        private var instance: AppUpdater? = null

        fun get(context: Context): AppUpdater =
            instance ?: synchronized(this) {
                instance ?: AppUpdater(context).also { instance = it }
            }
    }
}
