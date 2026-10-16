package com.legacy.legacytracker.tracking

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat

/**
 * Phone settings that stop or delay location updates. They ride along with
 * each upload (`tracking_issues`) so the people watching can be told why this
 * phone has gone quiet. The codes are the server's closed set
 * (`services/tracking-issues.ts`).
 */
object TrackingIssues {

    /** What the phone currently allows; [issues] turns it into codes. */
    data class Environment(
        val fineLocation: Boolean,
        val coarseLocation: Boolean,
        val backgroundLocation: Boolean,
        val locationServicesOn: Boolean,
        val batteryOptimizationIgnored: Boolean,
    )

    fun issues(env: Environment): List<String> = buildList {
        if (!env.locationServicesOn) add("location_services_off")
        val anyLocation = env.fineLocation || env.coarseLocation
        if (!anyLocation) {
            add("location_permission")
        } else {
            if (!env.backgroundLocation) add("background_location")
            // Approximate-only: routes can't be recorded from it.
            if (!env.fineLocation) add("precise_location")
        }
        if (!env.batteryOptimizationIgnored) add("battery_optimization")
    }

    fun detect(context: Context): List<String> {
        val app = context.applicationContext
        fun granted(permission: String) =
            ContextCompat.checkSelfPermission(app, permission) == PackageManager.PERMISSION_GRANTED

        val power = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val locationManager = app.getSystemService(Context.LOCATION_SERVICE) as? android.location.LocationManager
        return issues(
            Environment(
                fineLocation = granted(Manifest.permission.ACCESS_FINE_LOCATION),
                coarseLocation = granted(Manifest.permission.ACCESS_COARSE_LOCATION),
                backgroundLocation = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                    granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                // Can't tell → assume on rather than raise a false alarm.
                locationServicesOn = locationManager?.let { LocationManagerCompat.isLocationEnabled(it) } ?: true,
                batteryOptimizationIgnored = power?.isIgnoringBatteryOptimizations(app.packageName) ?: true,
            ),
        )
    }
}
