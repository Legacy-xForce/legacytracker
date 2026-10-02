package com.legacy.legacytracker.tracking

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class StopDetectorTest {

    private val origin = Track.ORIGIN
    private val timeout = 5 * 60_000L

    @Test
    fun parkedForTheTimeoutIsAStop() {
        val detector = StopDetector()
        val random = Random(7)
        var stop: Fix? = null
        for (s in 0..300) {
            val fix = Track.offset(origin, random.nextDouble(-8.0, 8.0), random.nextDouble(-8.0, 8.0), 1_000_000L + s * 1000L)
                .copy(accuracy = 10f, speed = 0.1f)
            stop = detector.offer(fix, timeout) ?: stop
            if (s < 300) assertNull("stopped early at $s s", stop)
        }
        assertNotNull(stop)
        // Timestamped at arrival, positioned at the cluster centre.
        assertEquals(1_000_000L, stop!!.time)
        assertTrue(GeoMath.distance(stop, origin) < 5.0)
    }

    @Test
    fun slowCrawlOutOfTheRadiusIsNotAStop() {
        val detector = StopDetector()
        // Traffic jam: 0.2 m/s for 10 minutes covers 120 m.
        for (s in 0..600) {
            val fix = Track.offset(origin, 0.2 * s, 0.0, s * 1000L).copy(accuracy = 5f, speed = 0.2f)
            assertNull("stopped at $s s", detector.offer(fix, timeout))
        }
    }

    @Test
    fun dopplerSpeedResetsTheCluster() {
        val detector = StopDetector()
        for (s in 0..200) detector.offer(origin.copy(time = s * 1000L, speed = 0f), timeout)
        detector.offer(origin.copy(time = 201_000L, speed = 6f), timeout)
        // The clock restarts after real movement.
        assertNull(detector.offer(origin.copy(time = 400_000L, speed = 0f), timeout))
        assertNotNull(detector.offer(origin.copy(time = 501_000L, speed = 0f), timeout))
    }

    @Test
    fun inaccurateIndoorFixesWidenTheRadius() {
        val detector = StopDetector()
        var stop: Fix? = null
        for (s in 0..300) {
            // Indoors: ±60 m wander reported with 50 m accuracy.
            val north = if (s % 2 == 0) 30.0 else -30.0
            val fix = Track.offset(origin, north, 0.0, s * 1000L).copy(accuracy = 50f)
            stop = detector.offer(fix, timeout) ?: stop
        }
        assertNotNull(stop)
    }
}
