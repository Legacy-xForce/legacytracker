package com.legacy.legacytracker.tracking

import android.location.Location
import kotlin.math.PI
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * One position observation. Kept independent of [Location] so the sampling
 * logic stays plain JVM code that unit tests can drive directly.
 */
data class Fix(
    /** UTC epoch milliseconds of the observation (not of its delivery). */
    val time: Long,
    val lat: Double,
    val lon: Double,
    /** Horizontal accuracy, metres (68% radius). [UNKNOWN_ACCURACY] if absent. */
    val accuracy: Float,
    /** Ground speed in m/s, negative when unknown. */
    val speed: Float = -1f,
    /** Direction of travel in degrees, negative when unknown. */
    val bearing: Float = -1f,
    val altitude: Double? = null,
) {
    val hasSpeed: Boolean get() = speed >= 0f
    val hasAccuracy: Boolean get() = accuracy < UNKNOWN_ACCURACY

    companion object {
        const val UNKNOWN_ACCURACY = Float.MAX_VALUE

        fun from(location: Location): Fix = Fix(
            time = location.time,
            lat = location.latitude,
            lon = location.longitude,
            accuracy = if (location.hasAccuracy()) location.accuracy else UNKNOWN_ACCURACY,
            speed = if (location.hasSpeed()) location.speed else -1f,
            bearing = if (location.hasBearing()) location.bearing else -1f,
            altitude = if (location.hasAltitude()) location.altitude else null,
        )
    }
}

object GeoMath {
    private const val EARTH_RADIUS_M = 6_371_008.8
    private const val METRES_PER_DEGREE = EARTH_RADIUS_M * PI / 180.0

    /** Great-circle distance in metres (haversine). */
    fun distance(aLat: Double, aLon: Double, bLat: Double, bLon: Double): Double {
        val dLat = Math.toRadians(bLat - aLat)
        val dLon = Math.toRadians(bLon - aLon)
        val h = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(aLat)) * cos(Math.toRadians(bLat)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * EARTH_RADIUS_M * asin(sqrt(h.coerceIn(0.0, 1.0)))
    }

    fun distance(a: Fix, b: Fix): Double = distance(a.lat, a.lon, b.lat, b.lon)

    /**
     * Distance in metres from [p] to the segment [a]→[b] (clamped to the
     * segment, so a point beyond either end measures to that end). Uses a
     * local equirectangular projection centred on [a] — error is far below a
     * metre over the few-hundred-metre spans the sampler works with.
     */
    fun distanceToSegment(p: Fix, a: Fix, b: Fix): Double {
        val cosLat = cos(Math.toRadians(a.lat))
        val bx = (b.lon - a.lon) * cosLat * METRES_PER_DEGREE
        val by = (b.lat - a.lat) * METRES_PER_DEGREE
        val px = (p.lon - a.lon) * cosLat * METRES_PER_DEGREE
        val py = (p.lat - a.lat) * METRES_PER_DEGREE
        val lengthSq = bx * bx + by * by
        val t = if (lengthSq <= 0.0) 0.0 else ((px * bx + py * by) / lengthSq).coerceIn(0.0, 1.0)
        val dx = px - t * bx
        val dy = py - t * by
        return sqrt(dx * dx + dy * dy)
    }
}
