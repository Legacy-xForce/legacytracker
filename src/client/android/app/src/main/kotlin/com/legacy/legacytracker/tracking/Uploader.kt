package com.legacy.legacytracker.tracking

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Sends recorded points to `POST /api/v1/location` in batches.
 *
 * Rows are deleted only after a 2xx, and the server ignores duplicates, so
 * every failure mode degrades to "send again later". One lock serialises the
 * engine's in-process uploads and WorkManager's, so they never interleave.
 */
class Uploader(context: Context, private val state: EngineState, private val store: TrackingStore) {

    sealed class Result {
        /** [liveTtlSeconds] is the server's current live state, when it said. */
        class Sent(val count: Int, val liveTtlSeconds: Int?) : Result()
        object NothingToSend : Result()
        object Offline : Result()
        object NotConfigured : Result()
        object AuthRejected : Result()
        class Failed(val reason: String) : Result()
    }

    private val appContext = context.applicationContext
    private val lock = Any()

    /**
     * Uploads every pending point, plus [livePoint] — a broadcast-only fix the
     * server shows to viewers but never stores. Blocking; call off the main
     * and engine threads.
     */
    fun uploadAll(livePoint: Fix? = null): Result = synchronized(lock) {
        val baseUrl = state.baseUrl
        if (baseUrl == null || state.authHeader == null) return Result.NotConfigured
        if (state.authFailed) return Result.AuthRejected
        if (!isOnline()) return Result.Offline

        var live = livePoint
        var sent = 0
        var liveTtl: Int? = null
        while (true) {
            // Re-read per batch: the previous response may have rotated it.
            val auth = state.authHeader ?: return Result.NotConfigured
            val batch = store.pending(Tuning.UPLOAD_BATCH_SIZE)
            if (batch.isEmpty() && live == null) break

            val body = JSONArray()
            for (point in batch) {
                body.put(pointJson(point.fix, point.source, point.battery, point.charging))
            }
            live?.let {
                val (level, charging) = battery()
                body.put(pointJson(it, SOURCE_LIVE, level, charging))
            }
            // The phone's settings as of now ride on the newest point; the
            // server keeps the latest report, so older queued points needn't.
            val issues = JSONArray(TrackingIssues.detect(appContext))
            (body.opt(body.length() - 1) as? JSONObject)?.put("tracking_issues", issues)

            val response = try {
                post("$baseUrl/api/v1/location", auth, body.toString())
            } catch (e: Exception) {
                return Result.Failed(e.javaClass.simpleName + ": " + (e.message ?: ""))
            }
            when (response.first) {
                in 200..299 -> {
                    // Saved before the next batch goes out: the server keeps
                    // accepting the old token only until this one is used.
                    parseDeviceToken(response.second)?.let { state.saveRotatedAuth("Device $it") }
                    if (batch.isNotEmpty()) store.deleteUpTo(batch.last().id)
                    sent += batch.size
                    live = null
                    liveTtl = parseLiveTtl(response.second) ?: liveTtl
                    if (batch.size < Tuning.UPLOAD_BATCH_SIZE) break
                }
                401, 403 -> return Result.AuthRejected
                else -> return Result.Failed("HTTP ${response.first}")
            }
        }
        if (sent == 0 && livePoint == null) Result.NothingToSend else Result.Sent(sent, liveTtl)
    }

    // Reading the sticky broadcast is cheap, but a trip can record many points
    // a minute and the level barely moves — cache briefly.
    private var batteryCache: Pair<Int?, Boolean?> = Pair(null, null)
    private var batteryReadAt = 0L

    /** (level 0–100, on power) — nulls when unavailable. */
    @Synchronized
    fun battery(): Pair<Int?, Boolean?> {
        val now = SystemClock.elapsedRealtime()
        if (batteryReadAt != 0L && now - batteryReadAt < 60_000) return batteryCache
        batteryReadAt = now
        batteryCache = try {
            val intent = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (intent == null) {
                Pair(null, null)
            } else {
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
                val percent = if (level >= 0 && scale > 0) (level * 100 / scale).coerceIn(0, 100) else null
                Pair(percent, plugged)
            }
        } catch (e: Exception) {
            Pair(null, null)
        }
        return batteryCache
    }

    fun isOnline(): Boolean {
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return true
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun post(url: String, auth: String, body: String): Pair<Int, String> {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", auth)
            // We store the replacement token the response may carry.
            if (auth.startsWith("Device ")) connection.setRequestProperty("X-Token-Rotation", "1")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            return Pair(code, text)
        } finally {
            connection.disconnect()
        }
    }

    private fun parseLiveTtl(body: String): Int? = try {
        val json = JSONObject(body)
        if (json.has("live_ttl_s")) json.getInt("live_ttl_s") else null
    } catch (e: Exception) {
        null
    }

    private fun parseDeviceToken(body: String): String? = try {
        JSONObject(body).optString("device_token").takeIf { it.isNotEmpty() }
    } catch (e: Exception) {
        null
    }

    companion object {
        const val SOURCE_LIVE = "live"

        private fun iso(time: Long): String =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(Date(time))

        fun pointJson(fix: Fix, source: String, battery: Int?, charging: Boolean?): JSONObject {
            val coords = JSONObject()
                .put("latitude", fix.lat)
                .put("longitude", fix.lon)
                .put("speed", if (fix.hasSpeed) fix.speed.toDouble() else 0.0)
            // Bearing is noise when (nearly) stationary.
            if (fix.bearing >= 0f && fix.speed >= 0.5f) coords.put("heading", fix.bearing.toDouble())
            if (fix.hasAccuracy) coords.put("accuracy", fix.accuracy.toDouble())
            fix.altitude?.let { if (!it.isNaN() && !it.isInfinite()) coords.put("altitude", it) }

            val json = JSONObject()
                .put("coords", coords)
                .put("timestamp", iso(fix.time))
                .put("source", source)
            battery?.let { json.put("battery_level", it) }
            charging?.let { json.put("is_charging", it) }
            return json
        }
    }
}
