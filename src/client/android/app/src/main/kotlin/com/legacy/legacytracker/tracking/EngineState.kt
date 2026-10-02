package com.legacy.legacytracker.tracking

import android.content.Context
import android.content.SharedPreferences

enum class TrackingMode { OFF, STATIONARY, MOVING }

/**
 * Configuration and state that must survive process death. Mode and anchor
 * changes are committed synchronously: the engine is routinely killed right
 * after it acts (a receiver finishing, the OS reclaiming memory), and the
 * next wake-up must see what the last one decided.
 */
class EngineState(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("lt_engine", Context.MODE_PRIVATE)

    // ── Configuration (set from Dart) ───────────────────────────────────────
    val baseUrl: String? get() = prefs.getString(K_BASE_URL, null)
    val authHeader: String? get() = prefs.getString(K_AUTH, null)
    val userId: String? get() = prefs.getString(K_USER, null)
    val batterySaver: Boolean get() = prefs.getBoolean(K_SAVER, false)

    fun saveConfig(baseUrl: String, authHeader: String, userId: String, batterySaver: Boolean) {
        prefs.edit()
            .putString(K_BASE_URL, baseUrl.trimEnd('/'))
            .putString(K_AUTH, authHeader)
            .putString(K_USER, userId)
            .putBoolean(K_SAVER, batterySaver)
            .putBoolean(K_AUTH_FAILED, false)
            .commit()
    }

    val hasCredentials: Boolean get() = baseUrl != null && authHeader != null

    var authFailed: Boolean
        get() = prefs.getBoolean(K_AUTH_FAILED, false)
        set(value) { prefs.edit().putBoolean(K_AUTH_FAILED, value).apply() }

    // ── Mode ────────────────────────────────────────────────────────────────
    var mode: TrackingMode
        get() = runCatching { TrackingMode.valueOf(prefs.getString(K_MODE, null) ?: "OFF") }
            .getOrDefault(TrackingMode.OFF)
        set(value) { prefs.edit().putString(K_MODE, value.name).commit() }

    /** Where the device is parked; centre of the stationary geofence. */
    var anchor: Fix?
        get() = readFix(K_ANCHOR)
        set(value) { writeFix(K_ANCHOR, value, commit = true) }

    /** Last point stored during the current trip (to resume after a kill). */
    var lastRecorded: Fix?
        get() = readFix(K_LAST_RECORDED)
        set(value) { writeFix(K_LAST_RECORDED, value, commit = false) }

    // ── Live / liveness ─────────────────────────────────────────────────────
    var liveUntil: Long
        get() = prefs.getLong(K_LIVE_UNTIL, 0L)
        set(value) { prefs.edit().putLong(K_LIVE_UNTIL, value).apply() }

    var lastPingAt: Long
        get() = prefs.getLong(K_LAST_PING, 0L)
        set(value) { prefs.edit().putLong(K_LAST_PING, value).apply() }

    var lastUploadOkAt: Long
        get() = prefs.getLong(K_LAST_UPLOAD_OK, 0L)
        set(value) { prefs.edit().putLong(K_LAST_UPLOAD_OK, value).apply() }

    var lastUploadError: String?
        get() = prefs.getString(K_LAST_UPLOAD_ERROR, null)
        set(value) { prefs.edit().putString(K_LAST_UPLOAD_ERROR, value).apply() }

    var lastFixAt: Long
        get() = prefs.getLong(K_LAST_FIX, 0L)
        set(value) { prefs.edit().putLong(K_LAST_FIX, value).apply() }

    var lastHeartbeatAt: Long
        get() = prefs.getLong(K_LAST_HEARTBEAT, 0L)
        set(value) { prefs.edit().putLong(K_LAST_HEARTBEAT, value).apply() }

    // ── Activity recognition ────────────────────────────────────────────────
    var lastActivity: Int
        get() = prefs.getInt(K_ACTIVITY, -1)
        set(value) { prefs.edit().putInt(K_ACTIVITY, value).apply() }

    var lastActivityAt: Long
        get() = prefs.getLong(K_ACTIVITY_AT, 0L)
        set(value) { prefs.edit().putLong(K_ACTIVITY_AT, value).apply() }

    fun clearRuntime() {
        prefs.edit()
            .remove(K_ANCHOR + "_lat")
            .remove(K_LAST_RECORDED + "_lat")
            .remove(K_LIVE_UNTIL)
            .remove(K_LAST_PING)
            .remove(K_LAST_UPLOAD_OK)
            .remove(K_LAST_UPLOAD_ERROR)
            .remove(K_LAST_FIX)
            .remove(K_LAST_HEARTBEAT)
            .remove(K_ACTIVITY)
            .remove(K_ACTIVITY_AT)
            .commit()
    }

    fun clearCredentials() {
        prefs.edit().remove(K_AUTH).remove(K_USER).remove(K_AUTH_FAILED).commit()
    }

    private fun readFix(key: String): Fix? {
        if (!prefs.contains(key + "_lat")) return null
        return Fix(
            time = prefs.getLong(key + "_time", 0L),
            lat = Double.fromBits(prefs.getLong(key + "_lat", 0L)),
            lon = Double.fromBits(prefs.getLong(key + "_lon", 0L)),
            accuracy = prefs.getFloat(key + "_acc", Fix.UNKNOWN_ACCURACY),
        )
    }

    private fun writeFix(key: String, fix: Fix?, commit: Boolean) {
        val editor = prefs.edit()
        if (fix == null) {
            editor.remove(key + "_lat").remove(key + "_lon").remove(key + "_acc").remove(key + "_time")
        } else {
            editor.putLong(key + "_lat", fix.lat.toRawBits())
                .putLong(key + "_lon", fix.lon.toRawBits())
                .putFloat(key + "_acc", fix.accuracy)
                .putLong(key + "_time", fix.time)
        }
        if (commit) editor.commit() else editor.apply()
    }

    private companion object {
        const val K_BASE_URL = "base_url"
        const val K_AUTH = "auth_header"
        const val K_USER = "user_id"
        const val K_SAVER = "battery_saver"
        const val K_AUTH_FAILED = "auth_failed"
        const val K_MODE = "mode"
        const val K_ANCHOR = "anchor"
        const val K_LAST_RECORDED = "last_recorded"
        const val K_LIVE_UNTIL = "live_until"
        const val K_LAST_PING = "last_ping"
        const val K_LAST_UPLOAD_OK = "last_upload_ok"
        const val K_LAST_UPLOAD_ERROR = "last_upload_error"
        const val K_LAST_FIX = "last_fix"
        const val K_LAST_HEARTBEAT = "last_heartbeat"
        const val K_ACTIVITY = "activity"
        const val K_ACTIVITY_AT = "activity_at"
    }
}
