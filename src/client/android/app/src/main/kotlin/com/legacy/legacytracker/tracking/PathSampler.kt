package com.legacy.legacytracker.tracking

import kotlin.math.abs
import kotlin.math.max

/**
 * Decides which raw GPS fixes are worth storing.
 *
 * Replay draws straight lines between stored points, so the only error that
 * matters is how far the real path strays from those lines. The GPS runs at
 * ~1 Hz while moving; this keeps a fix only when it is needed to hold that
 * error under [SamplerTuning.toleranceM] — an online "opening window" line
 * simplification. In practice: a point at every bend, almost nothing on a
 * straight road.
 *
 * A fix is stored when any of these holds (relative to the last stored point R):
 *  1. Deviation — some fix seen since R lies more than ε from the line R→now.
 *     The last fix before the bend becomes the stored vertex.
 *  2. Max spacing — straight-line travel since R reached
 *     clamp(speed × maxSpacingSeconds, min, max). Bounds staleness and how
 *     much path a crash/kill could lose, and keeps segments short enough for
 *     sensible replay timing.
 *  3. Speed change — |v − v_R| ≥ max(3 m/s, 30% of v_R), so the replay's
 *     speed readout follows braking and acceleration.
 * Nothing is stored within [SamplerTuning.minSpacingM] of R, which keeps GPS
 * jitter at low speed from producing clusters of points.
 */
data class SamplerTuning(
    val toleranceM: Double = 5.0,
    val minSpacingM: Double = 10.0,
    val maxSpacingSeconds: Double = 8.0,
    val maxSpacingMinM: Double = 30.0,
    val maxSpacingMaxM: Double = 200.0,
    val speedDeltaMinMs: Double = 3.0,
    val speedDeltaRatio: Double = 0.3,
) {
    companion object {
        val DEFAULT = SamplerTuning()

        /** Battery saver: fixes arrive less often, so accept a looser fit. */
        val SAVER = SamplerTuning(toleranceM = 12.0, minSpacingM = 15.0, maxSpacingMaxM = 300.0)
    }
}

class PathSampler(var tuning: SamplerTuning = SamplerTuning.DEFAULT) {

    class Recorded(val fix: Fix, val source: String)

    private var last: Fix? = null
    private val window = ArrayList<Fix>()
    private var departure: Fix? = null
    private var recordedInTrip = 0

    /** The most recently stored point, if any. */
    val lastRecorded: Fix? get() = last

    /**
     * Begins a trip. [departureAnchor] is where the device was parked; the
     * first stored point is placed there (at an estimated departure time) so
     * the replay starts at the parking spot even though movement is detected
     * only after the device has left the stationary geofence.
     */
    fun startTrip(departureAnchor: Fix?) {
        last = null
        window.clear()
        departure = departureAnchor
        recordedInTrip = 0
    }

    /** Continues a trip interrupted by process death, without a new trip_start. */
    fun resumeTrip(lastStored: Fix) {
        last = lastStored
        window.clear()
        departure = null
        recordedInTrip = 1
    }

    fun offer(fix: Fix): List<Recorded> {
        val out = ArrayList<Recorded>(2)

        val anchor = departure
        if (anchor != null) {
            departure = null
            val gap = GeoMath.distance(anchor, fix)
            if (gap >= tuning.minSpacingM && gap <= MAX_DEPARTURE_GAP_M && fix.time - anchor.time > 2) {
                val speed = if (fix.hasSpeed && fix.speed > 1f) fix.speed.toDouble() else ASSUMED_DEPARTURE_SPEED_MS
                val departedAt = clamp(fix.time - (gap / speed * 1000).toLong(), anchor.time + 1, fix.time - 1)
                record(anchor.copy(time = departedAt, speed = 0f, bearing = -1f), SOURCE_TRIP_START, out)
            } else {
                record(fix, SOURCE_TRIP_START, out)
                return out
            }
        }

        var reference = last
        if (reference == null) {
            record(fix, SOURCE_TRIP_START, out)
            return out
        }
        // Duplicate or out-of-order delivery (batched results can overlap).
        if (fix.time <= (window.lastOrNull() ?: reference).time) return out

        if (window.isNotEmpty() && maxDeviation(reference, fix) > tuning.toleranceM) {
            val vertex = window.last()
            if (GeoMath.distance(reference, vertex) >= tuning.minSpacingM) {
                record(vertex, SOURCE_MOVE, out)
                reference = vertex
            } else {
                // The bend sits inside the noise floor of R — start over.
                window.clear()
            }
        }

        val travelled = GeoMath.distance(reference, fix)
        if (travelled >= maxSpacing(reference, fix, travelled) ||
            (travelled >= tuning.minSpacingM && speedChanged(reference, fix))
        ) {
            record(fix, SOURCE_MOVE, out)
        } else {
            window.add(fix)
            if (window.size > MAX_WINDOW) decimateWindow()
        }
        return out
    }

    /**
     * Closes the trip: stores the pending tail of the path and the stop
     * point (timestamped at arrival). [stop] is null when the trip ended
     * without a known parking position.
     */
    fun finishTrip(stop: Fix?): List<Recorded> {
        val out = ArrayList<Recorded>(2)
        departure = null
        val reference = last
        if (reference != null) {
            val tail = window.lastOrNull { stop == null || it.time < stop.time }
            if (tail != null &&
                GeoMath.distance(reference, tail) >= tuning.minSpacingM &&
                (stop == null || GeoMath.distance(tail, stop) >= tuning.minSpacingM)
            ) {
                record(tail, SOURCE_MOVE, out)
            }
        }
        val previous = last
        if (stop != null && recordedInTrip > 0 && (previous == null || stop.time > previous.time)) {
            record(stop.copy(speed = 0f, bearing = -1f), SOURCE_TRIP_END, out)
        }
        last = null
        window.clear()
        recordedInTrip = 0
        return out
    }

    private fun record(fix: Fix, source: String, out: MutableList<Recorded>) {
        out.add(Recorded(fix, source))
        last = fix
        window.clear()
        recordedInTrip++
    }

    private fun maxDeviation(from: Fix, to: Fix): Double {
        var worst = 0.0
        for (p in window) {
            val d = GeoMath.distanceToSegment(p, from, to)
            if (d > worst) worst = d
        }
        return worst
    }

    private fun maxSpacing(from: Fix, to: Fix, travelled: Double): Double {
        val speed = if (to.hasSpeed) {
            to.speed.toDouble()
        } else {
            travelled / max(1.0, (to.time - from.time) / 1000.0)
        }
        return (speed * tuning.maxSpacingSeconds).coerceIn(tuning.maxSpacingMinM, tuning.maxSpacingMaxM)
    }

    private fun speedChanged(from: Fix, to: Fix): Boolean {
        if (!from.hasSpeed || !to.hasSpeed) return false
        val threshold = max(tuning.speedDeltaMinMs, tuning.speedDeltaRatio * from.speed)
        return abs(to.speed - from.speed) >= threshold
    }

    /** Halves a long window (e.g. a long red light) while keeping its newest fix. */
    private fun decimateWindow() {
        val kept = window.filterIndexed { index, _ -> index % 2 == 1 || index == window.lastIndex }
        window.clear()
        window.addAll(kept)
    }

    private fun clamp(value: Long, min: Long, max: Long): Long =
        if (min > max) max else value.coerceIn(min, max)

    companion object {
        const val SOURCE_MOVE = "move"
        const val SOURCE_TRIP_START = "trip_start"
        const val SOURCE_TRIP_END = "trip_end"

        private const val MAX_WINDOW = 400
        // Beyond this the parking anchor is unrelated to the trip (e.g. a
        // trip whose end was never seen) and must not be drawn as its start.
        private const val MAX_DEPARTURE_GAP_M = 3_000.0
        private const val ASSUMED_DEPARTURE_SPEED_MS = 1.5
    }
}
