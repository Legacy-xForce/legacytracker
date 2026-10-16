package com.legacy.legacytracker.tracking

import android.Manifest
import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Native location engine. Runs without Flutter: everything here is driven by
 * OS events, so tracking survives the app being swiped away, the process
 * dying, reboots and app updates.
 *
 * STATIONARY (the normal state) — no GPS, no foreground service, no
 * notification. Wake-ups come from hardware-assisted triggers that cost
 * next to nothing: a geofence around the parking spot, activity recognition
 * (vehicle / bicycle / running), and rare network-only fixes.
 *
 * MOVING — a short-lived location foreground service runs the GPS at ~1 Hz
 * and [PathSampler] stores only the fixes the replay needs. After a few
 * minutes without displacement the trip ends, GPS turns off and the
 * geofence is re-armed at the new parking spot. Android requires a
 * notification while this service runs; it is minimum-importance (no icon in
 * the status bar) and exists only for the duration of a trip.
 *
 * All state lives on one dedicated thread; public entry points post to it.
 */
class TrackingEngine private constructor(context: Context) {

    interface Listener {
        fun onEngineEvent(event: Map<String, Any?>)
    }

    private val app: Context = context.applicationContext
    private val thread = HandlerThread("lt-engine").apply { start() }
    val looper: Looper = thread.looper
    private val handler = Handler(looper)
    val state = EngineState(app)
    val store = TrackingStore.get(app)
    val uploader = Uploader(app, state, store)
    private val uploadExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "lt-upload") }
    private val fused by lazy { LocationServices.getFusedLocationProviderClient(app) }
    private val geofencing by lazy { LocationServices.getGeofencingClient(app) }
    private val activityRecognition by lazy { ActivityRecognition.getClient(app) }

    @Volatile
    var listener: Listener? = null

    /** Whether the app UI is on screen (set from Dart). Process-scoped. */
    var appVisible = false
        private set

    private var trip: TripSession? = null
    private var tripService: TripService? = null
    private var foregroundCallback: LocationCallback? = null
    private var foregroundPing: ForegroundPing? = null
    private var lastFixTime = 0L

    private var uploading = false
    private var queuedLive: Fix? = null
    private var pendingSince = 0L
    private var backoffUntil = 0L
    private var backoffMs = Tuning.UPLOAD_BACKOFF_MIN_MS
    private var lastRefusalAt = 0L
    private var alarmSetAt = 0L

    // ── Threading helpers ───────────────────────────────────────────────────

    fun post(block: () -> Unit) {
        handler.post { safely(block) }
    }

    /** Runs [block] on the engine thread, then [done] (always), e.g. to finish a receiver. */
    fun post(block: () -> Unit, done: () -> Unit) {
        handler.post {
            try {
                safely(block)
            } finally {
                done()
            }
        }
    }

    /** Runs [block] on the engine thread and waits for its result. */
    fun <T> call(timeoutMs: Long, block: () -> T): T? {
        if (Looper.myLooper() == looper) return block()
        val latch = CountDownLatch(1)
        var result: T? = null
        handler.post {
            try {
                safely { result = block() }
            } finally {
                latch.countDown()
            }
        }
        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return result
    }

    private fun safely(block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.e(TAG, "Engine error", t)
            runCatching { store.log("error", t.toString()) }
        }
    }

    // ── Commands from Dart ──────────────────────────────────────────────────

    fun configure(baseUrl: String, authHeader: String, userId: String, batterySaver: Boolean) {
        val previousUser = state.userId
        if (previousUser != null && previousUser != userId) {
            log("config", "Account changed — discarding ${store.pendingCount()} unsent point(s)")
            store.clearPoints()
            state.clearRuntime()
        }
        val wasRejected = state.authFailed
        state.saveConfig(baseUrl, authHeader, userId, batterySaver)
        if (wasRejected) log("upload", "Upload credentials refreshed")
        trip?.refreshProfile()
        maybeFlush(force = true)
    }

    fun start() {
        if (!state.hasCredentials) {
            log("lifecycle", "Start ignored: not configured")
            return
        }
        deleteLegacyNotificationChannel()
        if (state.mode == TrackingMode.OFF) {
            state.mode = TrackingMode.STATIONARY
            log("lifecycle", "Tracking enabled")
        }
        if (state.mode == TrackingMode.MOVING) {
            if (trip == null) recoverAfterProcessStart()
            requestActivityTransitions()
            WatchdogWorker.schedule(app)
        } else {
            armStationary()
            if (state.anchor == null) requestPing("first fix")
        }
        if (appVisible) startForegroundSession()
        emitState()
    }

    fun stop(clearData: Boolean) {
        val previous = state.mode
        state.mode = TrackingMode.OFF
        trip?.let { session ->
            trip = null
            session.stop()
            if (session.kind == SessionKind.TRIP) {
                for (r in session.finish(session.currentStop())) record(r.fix, r.source)
            }
        }
        stopTripService()
        stopForegroundSession()
        removeGeofence()
        removeActivityTransitions()
        removeLowPowerUpdates()
        cancelSessionAlarm()
        WatchdogWorker.cancel(app)
        if (clearData) {
            // Last chance to deliver what was recorded under these credentials.
            val result = uploader.uploadAll()
            log("lifecycle", "Final upload before sign-out: ${describe(result)}")
            UploadWorker.cancel(app)
            store.clearPoints()
            state.clearRuntime()
            state.clearCredentials()
        } else {
            maybeFlush(force = true)
        }
        log("lifecycle", "Tracking disabled (was ${previous.name.lowercase()})")
        emitState()
    }

    fun setAppVisible(visible: Boolean) {
        if (appVisible == visible) return
        appVisible = visible
        if (state.mode == TrackingMode.OFF) return
        if (visible) {
            if (state.mode == TrackingMode.MOVING) {
                trip?.refreshProfile()
            } else {
                startForegroundSession()
                // Opening the app refreshes our own position for everyone else.
                foregroundPing = ForegroundPing("app opened")
            }
            maybeFlush(force = true)
        } else {
            stopForegroundSession()
            trip?.refreshProfile()
        }
    }

    fun flush() = maybeFlush(force = true)

    // ── OS events ───────────────────────────────────────────────────────────

    fun onGeofenceIntent(intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            log("geofence", "Geofence error ${event.errorCode}")
            return
        }
        if (event.geofenceTransition != Geofence.GEOFENCE_TRANSITION_EXIT) return
        if (state.mode == TrackingMode.STATIONARY) enterMoving("left the parked area")
    }

    fun onActivityIntent(intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        for (event in result.transitionEvents) {
            if (event.transitionType != ActivityTransition.ACTIVITY_TRANSITION_ENTER) continue
            state.lastActivity = event.activityType
            state.lastActivityAt = System.currentTimeMillis()
            val name = activityName(event.activityType)
            log("activity", "Activity: $name")
            if (state.mode == TrackingMode.STATIONARY && event.activityType in TRIP_ACTIVITIES) {
                enterMoving("activity: $name")
            }
        }
    }

    fun onLowPowerIntent(intent: Intent) {
        if (!LocationResult.hasResult(intent)) return
        val location = LocationResult.extractResult(intent)?.lastLocation ?: return
        val fix = Fix.from(location)
        lastFixTime = max(lastFixTime, fix.time)
        if (state.mode != TrackingMode.STATIONARY || trip != null) return
        val anchor = state.anchor
        if (anchor == null) {
            if (fix.accuracy <= Tuning.PING_MAX_ACCURACY_M) {
                state.anchor = fix
                addGeofence(fix, initialExit = false)
            }
            return
        }
        val distance = GeoMath.distance(anchor, fix)
        if (fix.accuracy <= 2 * Tuning.PING_MAX_ACCURACY_M &&
            distance > max(Tuning.GEOFENCE_RADIUS_M.toDouble(), 2.0 * fix.accuracy)
        ) {
            enterMoving("network fix ${distance.roundToInt()} m from parked spot")
        }
    }

    fun onCommand(command: String, ttlSeconds: Int) {
        if (state.mode == TrackingMode.OFF) return
        when (command) {
            "live" -> {
                val wasLive = isLive()
                applyLiveTtl(ttlSeconds)
                val sincePing = System.currentTimeMillis() - state.lastPingAt
                if (!wasLive || sincePing > Tuning.PING_MIN_INTERVAL_MS) requestPing("someone opened the map")
            }
            "idle" -> applyLiveTtl(0)
            // Someone is waiting on this phone: skip the ping throttle. A trip in
            // progress sends its latest fix at once; a parked phone takes a fresh one.
            "refresh" -> requestPing("location refresh requested")
        }
    }

    fun onBoot() {
        if (state.mode == TrackingMode.OFF) return
        log("lifecycle", "Re-arming after reboot / app update")
        if (state.mode == TrackingMode.MOVING) {
            if (trip == null) recoverAfterProcessStart()
        } else {
            // Registrations don't survive a reboot. INITIAL_TRIGGER_EXIT also
            // catches a device that moved while it was off.
            armStationary(initialExit = true)
        }
    }

    fun onAlarm() {
        trip?.onTick()
    }

    /** Periodic safety net from WorkManager (worker thread, blocking). */
    fun runWatchdog() {
        val enabled = call(10_000) {
            if (state.mode == TrackingMode.OFF) {
                WatchdogWorker.cancel(app)
                false
            } else {
                if (state.mode == TrackingMode.MOVING && trip == null) {
                    recoverAfterProcessStart()
                } else if (state.mode == TrackingMode.STATIONARY && trip == null) {
                    armStationary(initialExit = true)
                    heartbeatIfDue()
                }
                true
            }
        } ?: false
        if (enabled) {
            val result = uploader.uploadAll()
            post { onBackgroundUploadResult(result) }
        }
    }

    // ── State transitions ───────────────────────────────────────────────────

    private fun enterMoving(reason: String) {
        if (state.mode == TrackingMode.OFF) return
        val current = trip
        if (current != null) {
            if (current.kind == SessionKind.PING) current.convertToTrip(reason)
            return
        }
        val session = TripSession(SessionKind.TRIP, reason)
        session.prepareNewTrip(state.anchor)
        beginTripMode(session, reason)
    }

    private fun beginTripMode(session: TripSession, reason: String) {
        state.mode = TrackingMode.MOVING
        trip = session
        removeGeofence()
        removeLowPowerUpdates()
        stopForegroundSession()
        log("state", "Moving ($reason)")
        val started = TripService.start(app, TripService.ACTION_TRIP, reason)
        if (started != TripService.StartResult.STARTED) {
            onTripStartRefused(session, started)
        }
        emitState()
    }

    private fun onTripStartRefused(session: TripSession, result: TripService.StartResult) {
        if (trip !== session) return
        trip = null
        session.stop()
        state.mode = TrackingMode.STATIONARY
        val now = SystemClock.elapsedRealtime()
        // A background-start refusal is retried by the geofence's initial
        // exit trigger (exit events are exempt); avoid looping if that fails too.
        val retry = result == TripService.StartResult.NOT_ALLOWED &&
            (lastRefusalAt == 0L || now - lastRefusalAt > 5 * 60_000L)
        lastRefusalAt = now
        log("state", "Trip recording could not start (${result.name.lowercase()})")
        armStationary(initialExit = retry)
        if (appVisible) startForegroundSession()
        emitState()
    }

    private fun endTrip(session: TripSession, stop: Fix?, why: String) {
        if (trip !== session) return
        trip = null
        session.stop()
        for (r in session.finish(stop)) record(r.fix, r.source)
        state.lastRecorded = null
        stop?.let { state.anchor = it }
        if (state.mode != TrackingMode.OFF) state.mode = TrackingMode.STATIONARY
        stopTripService()
        log("state", "Stationary ($why)")
        if (state.mode == TrackingMode.STATIONARY) armStationary()
        if (appVisible) startForegroundSession()
        maybeFlush(force = true)
        emitState()
    }

    /** A trip was running when the process died; resume it or park safely. */
    private fun recoverAfterProcessStart() {
        if (state.mode != TrackingMode.MOVING || trip != null) return
        val session = TripSession(SessionKind.TRIP, "resumed")
        session.prepareResume(state.lastRecorded, state.anchor)
        trip = session
        val started = TripService.start(app, TripService.ACTION_TRIP, "resumed")
        if (started != TripService.StartResult.STARTED) {
            trip = null
            state.lastRecorded?.let { state.anchor = it }
            state.lastRecorded = null
            state.mode = TrackingMode.STATIONARY
            log("state", "Interrupted trip parked at its last point")
            armStationary(initialExit = started == TripService.StartResult.NOT_ALLOWED)
        }
    }

    // ── Trip service coupling ───────────────────────────────────────────────

    fun attachTripService(service: TripService, action: String, reason: String) {
        tripService = service
        var session = trip
        if (session == null) {
            // Started by the system (sticky restart) rather than by us.
            if (action == TripService.ACTION_PING || state.mode == TrackingMode.OFF) {
                stopTripService()
                return
            }
            session = TripSession(SessionKind.TRIP, reason)
            session.prepareResume(state.lastRecorded, state.anchor)
            trip = session
            state.mode = TrackingMode.MOVING
            removeGeofence()
            removeLowPowerUpdates()
            log("state", "Trip resumed by the system")
        }
        session.start()
        service.showNotification(ping = session.kind == SessionKind.PING)
        emitState()
    }

    fun onTripServiceStartFailed(error: Exception) {
        val session = trip ?: return
        log("state", "Foreground service failed: ${error.javaClass.simpleName}")
        if (session.kind == SessionKind.PING) {
            trip = null
            session.stop()
            fallbackPing(session.reason)
        } else {
            onTripStartRefused(session, TripService.StartResult.FAILED)
        }
    }

    fun detachTripService(service: TripService) {
        if (tripService !== service) return
        tripService = null
        val session = trip ?: return
        // Stopped by the system or the user while we still needed it.
        log("state", "Trip service stopped externally")
        if (session.kind == SessionKind.TRIP) {
            endTrip(session, session.currentStop(), "service stopped")
        } else {
            trip = null
            session.stop()
        }
    }

    private fun stopTripService() {
        tripService?.let {
            tripService = null
            it.stopSelf()
        } ?: TripService.stop(app)
    }

    // ── Pings: one fresh fix on demand ──────────────────────────────────────

    private fun requestPing(reason: String) {
        if (state.mode == TrackingMode.OFF) return
        state.lastPingAt = System.currentTimeMillis()
        val current = trip
        when {
            current != null && current.kind == SessionKind.TRIP -> current.sendLiveSoon()
            current != null -> Unit // a ping is already in flight
            appVisible -> {
                startForegroundSession()
                foregroundPing = ForegroundPing(reason)
            }
            else -> {
                val session = TripSession(SessionKind.PING, reason)
                trip = session
                val started = TripService.start(app, TripService.ACTION_PING, reason)
                if (started != TripService.StartResult.STARTED) {
                    trip = null
                    log("ping", "No foreground start for ping (${started.name.lowercase()}) — network fix")
                    fallbackPing(reason)
                }
            }
        }
    }

    /** Ping without a foreground service: a quick (possibly cached) network fix. */
    @SuppressLint("MissingPermission")
    private fun fallbackPing(reason: String) {
        if (!hasLocationPermission()) {
            heartbeatNow()
            maybeFlush(force = true)
            return
        }
        val request = CurrentLocationRequest.Builder()
            .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
            .setMaxUpdateAgeMillis(5 * 60_000L)
            .setDurationMillis(10_000L)
            .build()
        try {
            fused.getCurrentLocation(request, null).addOnCompleteListener { task ->
                val location: Location? = if (task.isSuccessful) task.result else null
                post {
                    if (location != null) {
                        onPingFix(Fix.from(location), reason)
                    } else {
                        heartbeatNow()
                        maybeFlush(force = true)
                    }
                }
            }
        } catch (e: SecurityException) {
            heartbeatNow()
        }
    }

    private fun onPingFix(fix: Fix, reason: String) {
        lastFixTime = max(lastFixTime, fix.time)
        emitLocation(fix)
        if (fix.accuracy > Tuning.PING_MAX_ACCURACY_M) {
            // A cell-tower-grade fix would make the marker jump; the parking
            // spot is the better answer. Still report in (last seen, battery).
            log("ping", "Fix for \"$reason\" too coarse — sent the parked position")
            heartbeatNow()
            maybeFlush(force = true)
            return
        }
        record(fix, SOURCE_PING)
        maybeFlush(force = true)
        val anchor = state.anchor
        val distance = anchor?.let { GeoMath.distance(it, fix) } ?: 0.0
        log("ping", "Fresh fix for \"$reason\" (±${fix.accuracy.roundToInt()} m)")
        val moved = anchor != null && fix.accuracy <= Tuning.PING_MAX_ACCURACY_M &&
            distance > max(Tuning.GEOFENCE_RADIUS_M.toDouble(), 2.0 * fix.accuracy)
        if (moved) {
            enterMoving("${distance.roundToInt()} m from parked spot")
        } else if (anchor == null || (fix.accuracy + 5f < anchor.accuracy && distance <= anchor.accuracy + fix.accuracy)) {
            // First anchor, or a clearly better estimate of the same spot.
            val refined = if (anchor == null) fix else fix.copy(time = anchor.time)
            state.anchor = refined
            if (state.mode == TrackingMode.STATIONARY) addGeofence(refined, initialExit = false)
        }
    }

    private inner class ForegroundPing(val reason: String) {
        val startedAt = SystemClock.elapsedRealtime()
        var best: Fix? = null
    }

    // ── App visible while parked ────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun startForegroundSession() {
        if (foregroundCallback != null || state.mode == TrackingMode.OFF) return
        if (trip?.kind == SessionKind.TRIP || !hasLocationPermission()) return
        val callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                for (location in result.locations) onForegroundFix(Fix.from(location))
            }
        }
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1_000L)
            .setMinUpdateIntervalMillis(1_000L)
            .build()
        try {
            fused.requestLocationUpdates(request, callback, looper)
            foregroundCallback = callback
        } catch (e: SecurityException) {
            log("position", "Foreground updates refused: ${e.message}")
        }
    }

    private fun stopForegroundSession() {
        foregroundCallback?.let { fused.removeLocationUpdates(it) }
        foregroundCallback = null
    }

    private fun onForegroundFix(fix: Fix) {
        lastFixTime = max(lastFixTime, fix.time)
        emitLocation(fix)
        if (state.mode != TrackingMode.STATIONARY || trip != null) return

        foregroundPing?.let { ping ->
            if (ping.best == null || fix.accuracy < ping.best!!.accuracy) ping.best = fix
            val waited = SystemClock.elapsedRealtime() - ping.startedAt
            if (fix.accuracy <= Tuning.PING_GOOD_ACCURACY_M || waited >= 10_000L) {
                foregroundPing = null
                onPingFix(ping.best!!, ping.reason)
                if (state.mode != TrackingMode.STATIONARY) return
            }
        }

        val anchor = state.anchor ?: return
        if (fix.accuracy > Tuning.FOREGROUND_MOVE_ACCURACY_M) return
        val distance = GeoMath.distance(anchor, fix)
        if (distance > Tuning.FOREGROUND_MOVE_THRESHOLD_M &&
            (distance > Tuning.GEOFENCE_RADIUS_M || (fix.hasSpeed && fix.speed > 1f))
        ) {
            enterMoving("moving with the app open")
        }
    }

    // ── Arming the stationary triggers ──────────────────────────────────────

    private fun armStationary(initialExit: Boolean = false) {
        state.anchor?.let { addGeofence(it, initialExit) }
        requestActivityTransitions()
        requestLowPowerUpdates()
        cancelSessionAlarm()
        WatchdogWorker.schedule(app)
    }

    @SuppressLint("MissingPermission")
    private fun addGeofence(anchor: Fix, initialExit: Boolean) {
        if (!hasFineLocation() || !hasBackgroundLocation()) {
            log("geofence", "Not armed: needs precise location \"Allow all the time\"")
            return
        }
        val radius = max(Tuning.GEOFENCE_RADIUS_M, min(Tuning.GEOFENCE_MAX_RADIUS_M, anchor.accuracy * 2f))
        val fence = Geofence.Builder()
            .setRequestId(GEOFENCE_ID)
            .setCircularRegion(anchor.lat, anchor.lon, radius)
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_EXIT)
            .build()
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(if (initialExit) GeofencingRequest.INITIAL_TRIGGER_EXIT else 0)
            .addGeofence(fence)
            .build()
        try {
            geofencing.addGeofences(request, receiverIntent(TrackingReceiver.ACTION_GEOFENCE, RC_GEOFENCE, true))
                .addOnFailureListener { e -> post { log("geofence", "Could not arm: ${e.message}") } }
        } catch (e: SecurityException) {
            log("geofence", "Not armed: ${e.message}")
        }
    }

    private fun removeGeofence() {
        runCatching { geofencing.removeGeofences(listOf(GEOFENCE_ID)) }
    }

    @SuppressLint("MissingPermission")
    private fun requestActivityTransitions() {
        if (!hasActivityRecognition()) return
        val transitions = ACTIVITY_TYPES.map { type ->
            ActivityTransition.Builder()
                .setActivityType(type)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build()
        }
        try {
            activityRecognition.requestActivityTransitionUpdates(
                ActivityTransitionRequest(transitions),
                receiverIntent(TrackingReceiver.ACTION_ACTIVITY, RC_ACTIVITY, true),
            ).addOnFailureListener { e -> post { log("activity", "Could not register: ${e.message}") } }
        } catch (e: SecurityException) {
            log("activity", "Not registered: ${e.message}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun removeActivityTransitions() {
        if (!hasActivityRecognition()) return
        try {
            activityRecognition.removeActivityTransitionUpdates(
                receiverIntent(TrackingReceiver.ACTION_ACTIVITY, RC_ACTIVITY, true),
            )
        } catch (e: SecurityException) {
            // Permission revoked meanwhile; nothing is registered then.
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestLowPowerUpdates() {
        if (!hasLocationPermission() || !hasBackgroundLocation()) return
        val request = LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, Tuning.LOW_POWER_INTERVAL_MS)
            .setMinUpdateIntervalMillis(Tuning.LOW_POWER_MIN_INTERVAL_MS)
            .build()
        try {
            fused.requestLocationUpdates(request, receiverIntent(TrackingReceiver.ACTION_LOW_POWER, RC_LOW_POWER, true))
        } catch (e: SecurityException) {
            log("position", "Low-power updates refused: ${e.message}")
        }
    }

    private fun removeLowPowerUpdates() {
        runCatching {
            fused.removeLocationUpdates(receiverIntent(TrackingReceiver.ACTION_LOW_POWER, RC_LOW_POWER, true))
        }
    }

    private fun scheduleSessionAlarm() {
        val now = SystemClock.elapsedRealtime()
        if (alarmSetAt != 0L && now - alarmSetAt < 2 * 60_000L) return
        alarmSetAt = now
        val alarms = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            now + Tuning.SESSION_ALARM_MS,
            receiverIntent(TrackingReceiver.ACTION_ALARM, RC_ALARM, false),
        )
    }

    private fun cancelSessionAlarm() {
        alarmSetAt = 0L
        val alarms = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.cancel(receiverIntent(TrackingReceiver.ACTION_ALARM, RC_ALARM, false))
    }

    private fun receiverIntent(action: String, requestCode: Int, mutable: Boolean): PendingIntent {
        val intent = Intent(app, TrackingReceiver::class.java).setAction(action)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        flags = flags or when {
            // Play services fills in extras (the event), so these must be mutable.
            mutable && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> PendingIntent.FLAG_MUTABLE
            mutable -> 0
            else -> PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(app, requestCode, intent, flags)
    }

    // ── Recording and uploading ─────────────────────────────────────────────

    private fun record(fix: Fix, source: String) {
        val (battery, charging) = uploader.battery()
        store.insert(fix, source, battery, charging)
        if (pendingSince == 0L) pendingSince = SystemClock.elapsedRealtime()
        if (source != SOURCE_PING && source != SOURCE_HEARTBEAT) state.lastRecorded = fix
    }

    private fun heartbeatIfDue() {
        val now = System.currentTimeMillis()
        if (now - max(state.lastUploadOkAt, state.lastHeartbeatAt) < Tuning.HEARTBEAT_INTERVAL_MS) return
        heartbeatNow()
    }

    /**
     * Liveness while parked: re-sends the parking spot with its original
     * timestamp. The server already has that row, so nothing new is stored —
     * it only refreshes "last seen" and the battery level.
     */
    private fun heartbeatNow() {
        val anchor = state.anchor ?: return
        state.lastHeartbeatAt = System.currentTimeMillis()
        record(anchor, SOURCE_HEARTBEAT)
    }

    private fun maybeFlush(force: Boolean = false) {
        if (uploading || !state.hasCredentials || state.authFailed) return
        val now = SystemClock.elapsedRealtime()
        if (!force && now < backoffUntil) return
        if (pendingSince == 0L) {
            if (store.pendingCount() == 0L) return
            pendingSince = now
        }
        val due = force || isLive() || appVisible ||
            now - pendingSince >= Tuning.UPLOAD_MAX_AGE_MS ||
            store.pendingCount() >= Tuning.UPLOAD_MAX_PENDING
        if (due) startUpload(null)
    }

    private fun startUpload(live: Fix?) {
        if (uploading) {
            if (live != null) queuedLive = live
            return
        }
        uploading = true
        uploadExecutor.execute {
            val result = uploader.uploadAll(live)
            post { onUploadResult(result) }
        }
    }

    private fun onUploadResult(result: Uploader.Result) {
        uploading = false
        handleUploadResult(result)
        val remaining = store.pendingCount()
        pendingSince = when {
            remaining == 0L -> 0L
            result is Uploader.Result.Sent -> SystemClock.elapsedRealtime()
            else -> pendingSince
        }
        val live = queuedLive
        queuedLive = null
        if (live != null && isLive()) startUpload(live)
    }

    private fun onBackgroundUploadResult(result: Uploader.Result) {
        handleUploadResult(result)
        if (store.pendingCount() == 0L) pendingSince = 0L
    }

    private fun handleUploadResult(result: Uploader.Result) {
        when (result) {
            is Uploader.Result.Sent -> {
                state.lastUploadOkAt = System.currentTimeMillis()
                state.lastUploadError = null
                backoffUntil = 0L
                backoffMs = Tuning.UPLOAD_BACKOFF_MIN_MS
                result.liveTtlSeconds?.let { applyLiveTtl(it) }
                if (result.count > 0) log("upload", "Uploaded ${result.count} point(s)")
                emit(mapOf("type" to "upload", "ok" to true, "count" to result.count))
            }
            is Uploader.Result.Failed, Uploader.Result.Offline -> {
                val reason = describe(result)
                state.lastUploadError = reason
                backoffUntil = SystemClock.elapsedRealtime() + backoffMs
                backoffMs = min(backoffMs * 2, Tuning.UPLOAD_BACKOFF_MAX_MS)
                // WorkManager delivers once connectivity is back, even if
                // the process is gone by then.
                UploadWorker.enqueue(app)
                log("upload", "Upload deferred: $reason")
                emit(mapOf("type" to "upload", "ok" to false, "error" to reason))
            }
            Uploader.Result.AuthRejected -> {
                if (!state.authFailed) log("upload", "Server rejected the upload credentials")
                state.authFailed = true
                emit(mapOf("type" to "auth_required"))
            }
            Uploader.Result.NothingToSend, Uploader.Result.NotConfigured -> Unit
        }
    }

    private fun describe(result: Uploader.Result): String = when (result) {
        is Uploader.Result.Sent -> "sent ${result.count}"
        is Uploader.Result.Failed -> result.reason
        Uploader.Result.Offline -> "offline"
        Uploader.Result.AuthRejected -> "credentials rejected"
        Uploader.Result.NothingToSend -> "nothing to send"
        Uploader.Result.NotConfigured -> "not configured"
    }

    // ── Live mode ───────────────────────────────────────────────────────────

    fun isLive(): Boolean = System.currentTimeMillis() < state.liveUntil

    private fun applyLiveTtl(ttlSeconds: Int) {
        val wasLive = isLive()
        state.liveUntil = if (ttlSeconds > 0) System.currentTimeMillis() + ttlSeconds * 1000L else 0L
        val live = isLive()
        if (wasLive != live) {
            log("live", if (live) "Live mode on — someone is watching" else "Live mode off")
            trip?.refreshProfile()
            emitState()
        }
    }

    private fun lowPower(): Boolean {
        if (state.batterySaver) return true
        val (level, charging) = uploader.battery()
        return level != null && level <= Tuning.LOW_BATTERY_PERCENT && charging != true
    }

    // ── Status and events for the UI ────────────────────────────────────────

    fun status(): Map<String, Any?> {
        val anchor = state.anchor
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "mode" to state.mode.name.lowercase(),
            "configured" to state.hasCredentials,
            "authFailed" to state.authFailed,
            "live" to isLive(),
            "lowPower" to lowPower(),
            "pending" to store.pendingCount().toInt(),
            "lastUploadAt" to state.lastUploadOkAt.takeIf { it > 0 },
            "lastUploadError" to state.lastUploadError,
            "lastFixAt" to max(lastFixTime, state.lastFixAt).takeIf { it > 0 },
            "anchorLat" to anchor?.lat,
            "anchorLon" to anchor?.lon,
            "anchorAccuracy" to anchor?.takeIf { it.hasAccuracy }?.accuracy?.toDouble(),
            "stationarySince" to anchor?.time,
            "preciseLocation" to hasFineLocation(),
            "backgroundLocation" to hasBackgroundLocation(),
            "activityRecognition" to hasActivityRecognition(),
            "batteryOptimizationIgnored" to power.isIgnoringBatteryOptimizations(app.packageName),
            "notificationsEnabled" to NotificationManagerCompat.from(app).areNotificationsEnabled(),
            "issues" to TrackingIssues.detect(app),
        )
    }

    fun logs(limit: Int): List<Map<String, Any?>> = store.logs(limit).map {
        mapOf("ts" to it.time, "cat" to it.category, "msg" to it.message)
    }

    fun log(category: String, message: String) {
        Log.i(TAG, "[$category] $message")
        runCatching { store.log(category, message) }
    }

    private fun emit(event: Map<String, Any?>) {
        listener?.onEngineEvent(event)
    }

    private fun emitState() {
        if (listener == null) return
        emit(mapOf("type" to "state", "mode" to state.mode.name.lowercase(), "live" to isLive()))
    }

    private fun emitLocation(fix: Fix) {
        if (listener == null) return
        emit(
            mapOf(
                "type" to "location",
                "lat" to fix.lat,
                "lon" to fix.lon,
                "accuracy" to if (fix.hasAccuracy) fix.accuracy.toDouble() else null,
                "speed" to if (fix.hasSpeed) fix.speed.toDouble() else null,
                "heading" to if (fix.bearing >= 0f) fix.bearing.toDouble() else null,
                "time" to fix.time,
            ),
        )
    }

    // ── Permissions ─────────────────────────────────────────────────────────

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(app, permission) == PackageManager.PERMISSION_GRANTED

    private fun hasFineLocation() = granted(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasLocationPermission() =
        hasFineLocation() || granted(Manifest.permission.ACCESS_COARSE_LOCATION)

    private fun hasBackgroundLocation() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    private fun hasActivityRecognition() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || granted(Manifest.permission.ACTIVITY_RECOGNITION)

    private fun deleteLegacyNotificationChannel() {
        // The always-on channel of the previous foreground-task implementation.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            app.getSystemService(NotificationManager::class.java)?.deleteNotificationChannel("lt_location_tracking")
        }
    }

    // ── Trip / ping session ─────────────────────────────────────────────────

    /** GPS session while moving (TRIP) or while taking one fresh fix (PING). */
    private enum class SessionKind { TRIP, PING }

    private inner class TripSession(var kind: SessionKind, val reason: String) {
        private val sampler = PathSampler()
        private val stopDetector = StopDetector()
        private var callback: LocationCallback? = null
        private var profile: RequestProfile? = null
        private val startedAt = SystemClock.elapsedRealtime()
        private var lastFixElapsed = SystemClock.elapsedRealtime()
        private var lastFix: Fix? = null
        private var lastAccepted: Fix? = null
        private var rejectedJumps = 0
        private var pingBest: Fix? = null
        private var lastLiveSent: Fix? = null
        private var lastLiveAt = 0L
        private var liveSoon = false
        private val tick = Runnable { safely { onTick() } }

        fun prepareNewTrip(anchor: Fix?) = sampler.startTrip(anchor)

        fun prepareResume(lastRecorded: Fix?, anchor: Fix?) {
            if (lastRecorded != null &&
                System.currentTimeMillis() - lastRecorded.time < Tuning.RESUME_WINDOW_MS
            ) {
                sampler.resumeTrip(lastRecorded)
            } else {
                sampler.startTrip(anchor)
            }
        }

        fun start() {
            if (callback != null) return
            callback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    safely { for (location in result.locations) onFix(Fix.from(location)) }
                }
            }
            refreshProfile()
            scheduleTick()
        }

        fun stop() {
            callback?.let { fused.removeLocationUpdates(it) }
            callback = null
            profile = null
            handler.removeCallbacks(tick)
            cancelSessionAlarm()
        }

        fun finish(stop: Fix?): List<PathSampler.Recorded> = sampler.finishTrip(stop)

        fun currentStop(): Fix? = stopDetector.currentStop() ?: lastAccepted ?: lastFix

        @SuppressLint("MissingPermission")
        fun refreshProfile() {
            val cb = callback ?: return
            val wanted = when {
                kind == SessionKind.PING || appVisible || isLive() -> Tuning.MOVING_REALTIME
                lowPower() -> Tuning.MOVING_SAVER
                else -> Tuning.MOVING_NORMAL
            }
            if (wanted == profile) return
            profile = wanted
            sampler.tuning = if (wanted == Tuning.MOVING_SAVER) SamplerTuning.SAVER else SamplerTuning.DEFAULT
            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, wanted.intervalMs)
                .setMinUpdateIntervalMillis(min(1_000L, wanted.intervalMs))
                .setMaxUpdateDelayMillis(wanted.maxDelayMs)
                .setWaitForAccurateLocation(false)
                .build()
            try {
                fused.requestLocationUpdates(request, cb, looper)
                if (kind == SessionKind.TRIP) log("position", "GPS ${wanted.name} (${wanted.intervalMs / 1000.0}s)")
            } catch (e: SecurityException) {
                log("position", "GPS refused: ${e.message}")
            }
        }

        fun convertToTrip(why: String) {
            if (kind == SessionKind.TRIP) return
            kind = SessionKind.TRIP
            sampler.startTrip(state.anchor)
            state.mode = TrackingMode.MOVING
            removeGeofence()
            removeLowPowerUpdates()
            stopForegroundSession()
            tripService?.showNotification(ping = false)
            log("state", "Moving ($why)")
            refreshProfile()
            scheduleTick()
            emitState()
        }

        fun sendLiveSoon() {
            liveSoon = true
            val fix = lastFix
            if (fix != null && System.currentTimeMillis() - fix.time < 5_000L) maybeSendLive(fix)
        }

        private fun onFix(fix: Fix) {
            lastFixElapsed = SystemClock.elapsedRealtime()
            lastFix = fix
            lastFixTime = max(lastFixTime, fix.time)
            emitLocation(fix)

            if (kind == SessionKind.PING) {
                if (fix.accuracy <= Tuning.PING_GOOD_ACCURACY_M) {
                    completePing(fix)
                } else if (pingBest == null || fix.accuracy < pingBest!!.accuracy) {
                    pingBest = fix
                }
                return
            }

            if (isJump(fix)) return

            if (fix.accuracy <= Tuning.MAX_STOP_ACCURACY_M) {
                val stop = stopDetector.offer(fix, stopTimeout())
                if (stop != null) {
                    endTrip(this, stop, "no movement for ${stopTimeout() / 60_000} min")
                    return
                }
            }

            val maxAccuracy = if (profile == Tuning.MOVING_SAVER) {
                Tuning.MAX_RECORD_ACCURACY_SAVER_M
            } else {
                Tuning.MAX_RECORD_ACCURACY_M
            }
            if (fix.accuracy <= maxAccuracy) {
                lastAccepted = fix
                for (r in sampler.offer(fix)) record(r.fix, r.source)
            }

            if (isLive() || liveSoon) maybeSendLive(fix)
            maybeFlush()
        }

        /** Rejects teleports; three in a row means the old position was the outlier. */
        private fun isJump(fix: Fix): Boolean {
            val previous = lastAccepted ?: return false
            val seconds = (fix.time - previous.time) / 1000.0
            if (seconds <= 0) return true
            val slack = (if (previous.hasAccuracy) previous.accuracy else 50f) +
                (if (fix.hasAccuracy) fix.accuracy else 50f)
            val distance = GeoMath.distance(previous, fix)
            val jump = distance > 3 * slack && (distance - slack) / seconds > Tuning.MAX_PLAUSIBLE_SPEED_MS
            if (!jump) {
                rejectedJumps = 0
                return false
            }
            if (++rejectedJumps >= 3) {
                rejectedJumps = 0
                lastAccepted = null
                return false
            }
            return true
        }

        private fun stopTimeout(): Long {
            val still = state.lastActivity == DetectedActivity.STILL &&
                System.currentTimeMillis() - state.lastActivityAt < 15 * 60_000L
            return if (still) Tuning.STOP_TIMEOUT_STILL_MS else Tuning.STOP_TIMEOUT_MS
        }

        private fun maybeSendLive(fix: Fix) {
            if (fix.accuracy > Tuning.PING_MAX_ACCURACY_M) return
            val now = SystemClock.elapsedRealtime()
            val previous = lastLiveSent
            val due = liveSoon || previous == null ||
                now - lastLiveAt >= Tuning.LIVE_KEEPALIVE_MS ||
                (now - lastLiveAt >= Tuning.LIVE_MIN_INTERVAL_MS &&
                    GeoMath.distance(previous, fix) >= Tuning.LIVE_MIN_DISTANCE_M)
            if (!due) return
            liveSoon = false
            lastLiveSent = fix
            lastLiveAt = now
            startUpload(fix)
        }

        private fun completePing(fix: Fix?) {
            if (kind != SessionKind.PING) return
            if (fix == null) {
                log("ping", "No GPS fix within ${Tuning.PING_TIMEOUT_MS / 1000}s")
                endPing()
                heartbeatNow()
                maybeFlush(force = true)
                return
            }
            onPingFix(fix, reason)
            // onPingFix may have turned this ping into a trip.
            if (kind == SessionKind.PING) endPing()
        }

        private fun endPing() {
            if (trip !== this) return
            trip = null
            stop()
            stopTripService()
            emitState()
        }

        fun onTick() {
            if (trip !== this) return
            val now = SystemClock.elapsedRealtime()
            if (lastFixTime > state.lastFixAt) state.lastFixAt = lastFixTime
            if (kind == SessionKind.PING) {
                if (now - startedAt >= Tuning.PING_TIMEOUT_MS) {
                    completePing(pingBest ?: lastFix)
                    return
                }
            } else {
                if (now - lastFixElapsed >= Tuning.NO_FIX_TIMEOUT_MS) {
                    endTrip(this, currentStop(), "no GPS fixes for ${Tuning.NO_FIX_TIMEOUT_MS / 60_000} min")
                    return
                }
                refreshProfile()
                maybeFlush()
            }
            scheduleTick()
        }

        private fun scheduleTick() {
            handler.removeCallbacks(tick)
            handler.postDelayed(tick, if (kind == SessionKind.PING) 1_000L else Tuning.SESSION_TICK_MS)
            if (kind == SessionKind.TRIP) scheduleSessionAlarm()
        }
    }

    companion object {
        private const val TAG = "LtTracking"
        private const val GEOFENCE_ID = "lt_stationary"
        private const val RC_GEOFENCE = 7401
        private const val RC_ACTIVITY = 7402
        private const val RC_LOW_POWER = 7403
        private const val RC_ALARM = 7404

        const val SOURCE_PING = "ping"
        const val SOURCE_HEARTBEAT = "heartbeat"

        /** Activities that start a trip at once; walking waits for the geofence. */
        private val TRIP_ACTIVITIES = setOf(
            DetectedActivity.IN_VEHICLE,
            DetectedActivity.ON_BICYCLE,
            DetectedActivity.RUNNING,
        )
        private val ACTIVITY_TYPES = listOf(
            DetectedActivity.IN_VEHICLE,
            DetectedActivity.ON_BICYCLE,
            DetectedActivity.RUNNING,
            DetectedActivity.WALKING,
            DetectedActivity.STILL,
        )

        private fun activityName(type: Int) = when (type) {
            DetectedActivity.IN_VEHICLE -> "in vehicle"
            DetectedActivity.ON_BICYCLE -> "cycling"
            DetectedActivity.RUNNING -> "running"
            DetectedActivity.WALKING -> "walking"
            DetectedActivity.STILL -> "still"
            else -> "activity $type"
        }

        @Volatile
        private var instance: TrackingEngine? = null

        fun get(context: Context): TrackingEngine =
            instance ?: synchronized(this) {
                instance ?: TrackingEngine(context).also { engine ->
                    instance = engine
                    // Published first, so anything recovery triggers sees this instance.
                    engine.post { engine.recoverAfterProcessStart() }
                }
            }
    }
}
