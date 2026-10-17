package com.legacy.legacytracker.tracking

/** GPS request shape while a trip is recorded. */
data class RequestProfile(
    val name: String,
    val intervalMs: Long,
    /**
     * FLP batching: fixes are still computed every [intervalMs] but delivered
     * together, so the CPU can sleep between deliveries. 0 = deliver each fix
     * immediately (someone is watching).
     */
    val maxDelayMs: Long,
)

object Tuning {
    // ── Stationary ──────────────────────────────────────────────────────────
    /**
     * Stationary geofence radius. Play services needs ≥100–150 m for reliable
     * exits (Wi-Fi positioning is ~20–50 m); smaller fences fire on drift.
     */
    const val GEOFENCE_RADIUS_M = 150f
    const val GEOFENCE_MAX_RADIUS_M = 500f
    /** Network-only fixes while parked: a fallback motion trigger, ~free. */
    const val LOW_POWER_INTERVAL_MS = 15 * 60_000L
    const val LOW_POWER_MIN_INTERVAL_MS = 2 * 60_000L
    /** Liveness ping when nothing has reached the server for this long. */
    const val HEARTBEAT_INTERVAL_MS = 25 * 60_000L
    const val WATCHDOG_INTERVAL_MINUTES = 30L

    // ── Moving ──────────────────────────────────────────────────────────────
    val MOVING_NORMAL = RequestProfile("normal", intervalMs = 2_000, maxDelayMs = 30_000)
    val MOVING_REALTIME = RequestProfile("realtime", intervalMs = 1_000, maxDelayMs = 0)
    val MOVING_SAVER = RequestProfile("saver", intervalMs = 5_000, maxDelayMs = 120_000)

    /** Fixes worse than this are used for stop detection but never stored. */
    const val MAX_RECORD_ACCURACY_M = 40f
    const val MAX_RECORD_ACCURACY_SAVER_M = 60f
    const val MAX_STOP_ACCURACY_M = 100f
    /** Implied speed between consecutive fixes above this is a GPS jump. */
    const val MAX_PLAUSIBLE_SPEED_MS = 90.0

    /**
     * A trip must get at least this far from where it started (same as the
     * geofence radius) or it is treated as GPS jitter and discarded.
     */
    const val MIN_TRIP_EXTENT_M = GEOFENCE_RADIUS_M.toDouble()

    const val STOP_TIMEOUT_MS = 5 * 60_000L
    /** Activity recognition says STILL: trust it and stop sooner. */
    const val STOP_TIMEOUT_STILL_MS = 2 * 60_000L
    /** No fix at all (garage, tunnel) for this long ends the trip. */
    const val NO_FIX_TIMEOUT_MS = 5 * 60_000L
    const val SESSION_TICK_MS = 20_000L
    /** Inexact wake-up backstop in case the CPU sleeps through the tick. */
    const val SESSION_ALARM_MS = 6 * 60_000L
    /** A trip interrupted by process death resumes if it is this recent. */
    const val RESUME_WINDOW_MS = 10 * 60_000L

    // ── Uploads ─────────────────────────────────────────────────────────────
    const val UPLOAD_BATCH_SIZE = 500
    /** Not live: upload when the oldest pending point is this old ... */
    const val UPLOAD_MAX_AGE_MS = 5 * 60_000L
    /** ... or this many points are waiting. */
    const val UPLOAD_MAX_PENDING = 200
    const val UPLOAD_BACKOFF_MIN_MS = 30_000L
    const val UPLOAD_BACKOFF_MAX_MS = 10 * 60_000L

    // ── Live (someone is watching) ──────────────────────────────────────────
    const val LIVE_MIN_INTERVAL_MS = 2_500L
    const val LIVE_MIN_DISTANCE_M = 8.0
    const val LIVE_KEEPALIVE_MS = 30_000L
    /** Renewals don't re-ping a parked device more often than this. */
    const val PING_MIN_INTERVAL_MS = 10 * 60_000L

    // ── On-demand fix ───────────────────────────────────────────────────────
    const val PING_GOOD_ACCURACY_M = 20f
    const val PING_TIMEOUT_MS = 15_000L
    const val PING_MAX_ACCURACY_M = 100f

    // ── App visible ─────────────────────────────────────────────────────────
    /** With fresh GPS on screen, this much displacement from the anchor is a trip. */
    const val FOREGROUND_MOVE_THRESHOLD_M = 60.0
    const val FOREGROUND_MOVE_ACCURACY_M = 30f

    const val LOW_BATTERY_PERCENT = 15

    // ── Storage ─────────────────────────────────────────────────────────────
    const val MAX_STORED_POINTS = 100_000
    const val MAX_LOG_ENTRIES = 500
}
