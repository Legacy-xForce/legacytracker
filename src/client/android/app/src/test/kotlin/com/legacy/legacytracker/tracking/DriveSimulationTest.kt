package com.legacy.legacytracker.tracking

import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/**
 * End-to-end check of the sampler on a realistic mixed drive with correlated
 * GPS noise: how many of the 1 Hz fixes it keeps, and how far the replay line
 * strays from the path that was actually driven.
 */
class DriveSimulationTest {

    private sealed class Leg {
        class Straight(val metres: Double, val speed: Double) : Leg()
        class Turn(val radius: Double, val degrees: Double, val speed: Double) : Leg()
        class Wait(val seconds: Int) : Leg()
    }

    private class Sample(val truth: Fix, val gps: Fix)

    @Test
    fun mixedDriveCompressesAndStaysOnTheRoad() {
        val legs = listOf(
            Leg.Straight(400.0, 13.9), // city block run at 50 km/h
            Leg.Wait(30), // red light
            Leg.Turn(radius = 12.0, degrees = 90.0, speed = 5.0), // right turn at the junction
            Leg.Straight(600.0, 13.0),
            Leg.Turn(radius = 25.0, degrees = -270.0, speed = 7.0), // roundabout, third exit
            Leg.Straight(300.0, 16.0),
            Leg.Straight(2_000.0, 30.0), // highway, 108 km/h
            Leg.Turn(radius = 800.0, degrees = 30.0, speed = 30.0), // sweeping highway bend
            Leg.Straight(1_500.0, 30.0),
            Leg.Turn(radius = 60.0, degrees = -90.0, speed = 12.0), // exit ramp
            Leg.Straight(500.0, 12.0),
            Leg.Wait(20),
        )
        val samples = simulate(legs, Random(2026))

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

    /** 1 Hz kinematic simulation with acceleration limits and AR(1) GPS noise. */
    private fun simulate(legs: List<Leg>, random: Random): List<Sample> {
        val out = ArrayList<Sample>()
        var x = 0.0
        var y = 0.0
        var heading = 0.0 // radians, 0 = north, clockwise
        var speed = 0.0
        var t = 0L
        var noiseX = 0.0
        var noiseY = 0.0
        val accel = 2.5

        fun emit() {
            noiseX = 0.9 * noiseX + random.nextDouble(-1.0, 1.0)
            noiseY = 0.9 * noiseY + random.nextDouble(-1.0, 1.0)
            val truth = Track.offset(Track.ORIGIN, y, x, t * 1000L)
                .copy(speed = speed.toFloat(), bearing = ((Math.toDegrees(heading) % 360 + 360) % 360).toFloat())
            val gps = Track.offset(Track.ORIGIN, y + noiseY, x + noiseX, t * 1000L)
                .copy(
                    accuracy = 4f + random.nextFloat() * 4f,
                    speed = max(0.0, speed + random.nextDouble(-0.3, 0.3)).toFloat(),
                    bearing = truth.bearing,
                )
            out += Sample(truth, gps)
            t++
        }

        fun approach(target: Double) {
            speed = if (speed < target) min(target, speed + accel) else max(target, speed - accel)
        }

        for (leg in legs) {
            when (leg) {
                is Leg.Straight -> {
                    var travelled = 0.0
                    while (travelled < leg.metres) {
                        approach(leg.speed)
                        val step = min(speed, leg.metres - travelled)
                        x += step * sin(heading)
                        y += step * cos(heading)
                        travelled += step
                        emit()
                    }
                }
                is Leg.Turn -> {
                    val total = Math.toRadians(abs(leg.degrees))
                    val direction = if (leg.degrees >= 0) 1.0 else -1.0
                    var turned = 0.0
                    while (turned < total) {
                        approach(leg.speed)
                        val dTheta = min(speed / leg.radius, total - turned)
                        // Advance along the arc chord for this second.
                        val mid = heading + direction * dTheta / 2
                        val chord = 2 * leg.radius * sin(dTheta / 2)
                        x += chord * sin(mid)
                        y += chord * cos(mid)
                        heading += direction * dTheta
                        turned += dTheta
                        emit()
                    }
                    heading %= 2 * PI
                }
                is Leg.Wait -> {
                    while (speed > 0) {
                        approach(0.0)
                        x += speed * sin(heading)
                        y += speed * cos(heading)
                        emit()
                    }
                    repeat(leg.seconds) { emit() }
                }
            }
        }
        return out
    }
}
