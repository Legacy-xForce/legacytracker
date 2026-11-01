package com.legacy.legacytracker.tracking

import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.max

/**
 * End-to-end check of the sampler on a realistic mixed drive with correlated
 * GPS noise: how many of the 1 Hz fixes it keeps, and how far the replay line
 * strays from the path that was actually driven.
 */
class DriveSimulationTest {

    @Test
    fun mixedDriveCompressesAndStaysOnTheRoad() {
        val samples = DriveSim.mixedDrive()

        val sampler = PathSampler()
        sampler.startTrip(null)
        val stored = ArrayList<Fix>()
        for (sample in samples) stored += sampler.offer(sample.gps).map { it.fix }
        stored += sampler.finishTrip(samples.last().gps).map { it.fix }

        var worst = 0.0
        var sum = 0.0
        for (sample in samples) {
            val distance = (1 until stored.size).minOf { i ->
                GeoMath.distanceToSegment(sample.truth, stored[i - 1], stored[i])
            }
            worst = max(worst, distance)
            sum += distance
        }
        val mean = sum / samples.size
        val ratio = samples.size.toDouble() / stored.size
        println(
            "drive: ${samples.size} fixes -> ${stored.size} stored (%.1fx), " .format(ratio) +
                "replay error vs true path: mean %.2f m, max %.2f m".format(mean, worst),
        )

        assertTrue("compression only %.1fx".format(ratio), ratio >= 5.0)
        // ε (5 m) plus the GPS noise carried by the stored points themselves.
        assertTrue("max replay error %.2f m".format(worst), worst <= 9.0)
        assertTrue("mean replay error %.2f m".format(mean), mean <= 3.0)
    }
}
