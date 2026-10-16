package com.legacy.legacytracker.tracking

import org.junit.Assert.assertEquals
import org.junit.Test

class TrackingIssuesTest {

    private val healthy = TrackingIssues.Environment(
        fineLocation = true,
        coarseLocation = true,
        backgroundLocation = true,
        locationServicesOn = true,
        batteryOptimizationIgnored = true,
    )

    @Test
    fun `a fully configured phone reports nothing`() {
        assertEquals(emptyList<String>(), TrackingIssues.issues(healthy))
    }

    @Test
    fun `battery optimization alone is reported`() {
        assertEquals(
            listOf("battery_optimization"),
            TrackingIssues.issues(healthy.copy(batteryOptimizationIgnored = false)),
        )
    }

    @Test
    fun `location switched off phone-wide is reported`() {
        assertEquals(
            listOf("location_services_off"),
            TrackingIssues.issues(healthy.copy(locationServicesOn = false)),
        )
    }

    @Test
    fun `no permission at all reports only the missing permission`() {
        // Background and precise are moot without any permission.
        assertEquals(
            listOf("location_permission"),
            TrackingIssues.issues(
                healthy.copy(fineLocation = false, coarseLocation = false, backgroundLocation = false),
            ),
        )
    }

    @Test
    fun `while-in-use and approximate location are reported separately`() {
        assertEquals(
            listOf("background_location"),
            TrackingIssues.issues(healthy.copy(backgroundLocation = false)),
        )
        assertEquals(
            listOf("precise_location"),
            TrackingIssues.issues(healthy.copy(fineLocation = false)),
        )
    }

    @Test
    fun `several problems are all reported, most blocking first`() {
        assertEquals(
            listOf("location_services_off", "background_location", "battery_optimization"),
            TrackingIssues.issues(
                healthy.copy(
                    locationServicesOn = false,
                    backgroundLocation = false,
                    batteryOptimizationIgnored = false,
                ),
            ),
        )
    }
}
