package com.legacy.legacytracker.tracking

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

class PathSamplerTest {

    private val origin = Track.ORIGIN

    @Test
    fun straightRoadKeepsOnlySpacedPoints() {
        // 2 km north at 50 km/h, one fix per second.
        val fixes = Track.line(origin, bearingDeg = 0.0, speedMs = 13.9, seconds = 144)
        val stored = run(fixes)

        assertEquals(PathSampler.SOURCE_TRIP_START, stored.first().source)
        // max spacing = 8 s × 13.9 m/s ≈ 111 m → roughly 2000 / 111 points.
        assertTrue("stored ${stored.size}", stored.size in 15..22)
        assertSpacing(stored.map { it.fix })
    }

    @Test
    fun cornerBecomesAVertex() {
        // 300 m north, then a right angle and 300 m east, at 10 m/s.
        val fixes = Track.line(origin, 0.0, 10.0, 30) +
            Track.line(Track.offset(origin, 300.0, 0.0, 30_000), 90.0, 10.0, 30, startIndex = 1)
        val stored = run(fixes)
        val corner = Track.offset(origin, 300.0, 0.0, 0)

        val nearest = stored.minOf { GeoMath.distance(it.fix, corner) }
        assertTrue("closest stored point is ${nearest} m from the corner", nearest <= 10.0)
        assertDeviationWithin(stored.map { it.fix }, fixes, toleranceM = 5.5)
    }

    @Test
    fun curvyRoadStaysWithinTolerance() {
        // Two laps of a 50 m radius roundabout at 8 m/s.
        val fixes = Track.circle(origin, radiusM = 50.0, speedMs = 8.0, seconds = 80)
        val stored = run(fixes)

        assertDeviationWithin(stored.map { it.fix }, fixes, toleranceM = 5.5)
        assertTrue("a curve needs many vertices, got ${stored.size}", stored.size >= 12)
        assertSpacing(stored.map { it.fix })
    }

    @Test
    fun parkedJitterStoresNothing() {
        val random = Random(42)
        val sampler = PathSampler()
        sampler.startTrip(null)
        val stored = ArrayList<PathSampler.Recorded>()
        for (i in 0 until 180) {
            val jitter = Track.offset(origin, random.nextDouble(-3.0, 3.0), random.nextDouble(-3.0, 3.0), i * 1000L)
            stored += sampler.offer(jitter.copy(accuracy = 8f, speed = 0.2f))
        }
        assertEquals(1, stored.size)
        assertEquals(PathSampler.SOURCE_TRIP_START, stored.single().source)
    }

    @Test
    fun departureStartsAtTheParkingSpot() {
        val parked = origin.copy(time = 0L, accuracy = 6f)
        val sampler = PathSampler()
        sampler.startTrip(parked)
        // First fix arrives 600 s later, 200 m away, at 10 m/s (geofence exit latency).
        val first = Track.offset(origin, 200.0, 0.0, 600_000L).copy(speed = 10f)
        val stored = sampler.offer(first)

        assertEquals(2, stored.size)
        assertEquals(PathSampler.SOURCE_TRIP_START, stored[0].source)
        assertEquals(parked.lat, stored[0].fix.lat, 1e-9)
        // Departure is estimated from distance / speed: 200 m at 10 m/s → 20 s earlier.
        assertEquals(580_000L, stored[0].fix.time)
        assertEquals(first, stored[1].fix)
    }

    @Test
    fun finishStoresTailAndStop() {
        val sampler = PathSampler()
        sampler.startTrip(null)
        val fixes = Track.line(origin, 0.0, 10.0, 6)
        fixes.forEach { sampler.offer(it) }
        val stop = Track.offset(origin, 70.0, 0.0, 7_000L)

        val closing = sampler.finishTrip(stop)
        assertEquals(PathSampler.SOURCE_TRIP_END, closing.last().source)
        assertEquals(0f, closing.last().fix.speed)
        assertTrue(closing.size == 2) // pending tail at ~50 m, then the stop
        assertTrue(sampler.lastRecorded == null)
    }

    @Test
    fun speedChangeIsCaptured() {
        val sampler = PathSampler()
        sampler.startTrip(null)
        sampler.offer(origin.copy(speed = 15f))
        // Hard braking: 15 → 8 m/s within ~25 m.
        val braking = Track.offset(origin, 25.0, 0.0, 2_000L).copy(speed = 8f)
        val stored = sampler.offer(braking)
        assertEquals(1, stored.size)
        assertEquals(8f, stored.single().fix.speed)
    }

    @Test
    fun outOfOrderFixesAreIgnored() {
        val sampler = PathSampler()
        sampler.startTrip(null)
        sampler.offer(origin)
        sampler.offer(Track.offset(origin, 5.0, 0.0, 2_000L))
        assertTrue(sampler.offer(Track.offset(origin, 300.0, 0.0, 1_000L)).isEmpty())
    }

    private fun run(fixes: List<Fix>): List<PathSampler.Recorded> {
        val sampler = PathSampler()
        sampler.startTrip(null)
        val out = ArrayList<PathSampler.Recorded>()
        fixes.forEach { out += sampler.offer(it) }
        out += sampler.finishTrip(null)
        return out
    }

    private fun assertSpacing(points: List<Fix>) {
        for (i in 1 until points.size) {
            val gap = GeoMath.distance(points[i - 1], points[i])
            assertTrue("gap $gap m below the noise floor", gap >= 10.0 - 1e-6)
            assertTrue("gap $gap m above max spacing", gap <= 200.0 + 15.0)
        }
    }

    /** Every raw fix lies within [toleranceM] of the stored polyline. */
    private fun assertDeviationWithin(polyline: List<Fix>, raw: List<Fix>, toleranceM: Double) {
        for (fix in raw) {
            val distance = (1 until polyline.size).minOf { i ->
                GeoMath.distanceToSegment(fix, polyline[i - 1], polyline[i])
            }
            assertTrue("fix ${fix.time} is $distance m off the replay line", distance <= toleranceM)
        }
    }
}

/** Synthetic GPS tracks in a local metric frame around a fixed origin. */
object Track {
    val ORIGIN = Fix(time = 0L, lat = 45.0703, lon = 7.6869, accuracy = 5f, speed = 0f)

    fun offset(base: Fix, northM: Double, eastM: Double, time: Long): Fix {
        val lat = base.lat + northM / 111_195.0
        val lon = base.lon + eastM / (111_195.0 * cos(Math.toRadians(base.lat)))
        return Fix(time = time, lat = lat, lon = lon, accuracy = 5f)
    }

    fun line(
        start: Fix,
        bearingDeg: Double,
        speedMs: Double,
        seconds: Int,
        startIndex: Int = 0,
    ): List<Fix> {
        val rad = Math.toRadians(bearingDeg)
        return (startIndex..seconds).map { s ->
            val d = speedMs * s
            offset(start, d * cos(rad), d * sin(rad), start.time + s * 1000L)
                .copy(speed = speedMs.toFloat(), bearing = bearingDeg.toFloat())
        }
    }

    fun circle(centre: Fix, radiusM: Double, speedMs: Double, seconds: Int): List<Fix> {
        val omega = speedMs / radiusM
        return (0..seconds).map { s ->
            val angle = omega * s
            offset(centre, radiusM * cos(angle), radiusM * sin(angle), s * 1000L)
                .copy(speed = speedMs.toFloat(), bearing = ((Math.toDegrees(angle) + 90) % 360 + 360).toFloat() % 360f)
        }.also { check(omega * seconds > 2 * PI) }
    }
}
