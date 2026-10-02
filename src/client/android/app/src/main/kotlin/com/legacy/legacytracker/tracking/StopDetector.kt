package com.legacy.legacytracker.tracking

import kotlin.math.max
import kotlin.math.min

/**
 * Decides when a trip has ended: every fix for `timeoutMs` stayed within a
 * small radius of the cluster's (accuracy-weighted) centre. GPS position
 * wanders a few metres even when parked and far more indoors, so the radius
 * grows with the reported accuracy; a reliable Doppler speed above walking
 * pace resets the cluster immediately.
 */
class StopDetector(
    private val radiusM: Double = 40.0,
    private val maxRadiusM: Double = 100.0,
) {
    private var start: Fix? = null
    private var weightSum = 0.0
    private var latSum = 0.0
    private var lonSum = 0.0
    private var bestAccuracy = Fix.UNKNOWN_ACCURACY

    fun reset() {
        start = null
        weightSum = 0.0
        latSum = 0.0
        lonSum = 0.0
        bestAccuracy = Fix.UNKNOWN_ACCURACY
    }

    /**
     * Feeds a fix. Returns the stop — centre of the cluster, timestamped at
     * arrival — once the device has stayed put for [timeoutMs]; null otherwise.
     */
    fun offer(fix: Fix, timeoutMs: Long): Fix? {
        val first = start
        val movingFast = fix.hasSpeed && fix.speed > MOVING_SPEED_MS
        if (first == null || movingFast || !insideCluster(fix)) {
            begin(fix)
            return null
        }
        add(fix)
        return if (fix.time - first.time >= timeoutMs) currentStop() else null
    }

    /** The cluster so far as a stop, regardless of how long it has lasted. */
    fun currentStop(): Fix? {
        val first = start ?: return null
        return Fix(
            time = first.time,
            lat = latSum / weightSum,
            lon = lonSum / weightSum,
            accuracy = bestAccuracy,
            speed = 0f,
        )
    }

    /**
     * Within the radius of both the centre (robust to one bad fix) and the
     * first fix — the latter so a slow, steady crawl (traffic jam) eventually
     * leaves the cluster instead of dragging its centre along with it.
     */
    private fun insideCluster(fix: Fix): Boolean {
        val first = start ?: return false
        val radius = max(radiusM, min(maxRadiusM, 1.5 * fix.accuracy))
        return GeoMath.distance(first, fix) <= radius &&
            GeoMath.distance(latSum / weightSum, lonSum / weightSum, fix.lat, fix.lon) <= radius
    }

    private fun begin(fix: Fix) {
        reset()
        start = fix
        add(fix)
    }

    private fun add(fix: Fix) {
        // Inverse-variance weighting: a 5 m GPS fix outweighs a 50 m one 100:1.
        val accuracy = max(3.0, if (fix.hasAccuracy) fix.accuracy.toDouble() else maxRadiusM)
        val weight = 1.0 / (accuracy * accuracy)
        weightSum += weight
        latSum += fix.lat * weight
        lonSum += fix.lon * weight
        if (fix.accuracy < bestAccuracy) bestAccuracy = fix.accuracy
    }

    companion object {
        /** Doppler speed above walking pace means we are definitely moving. */
        const val MOVING_SPEED_MS = 2.5f
    }
}
