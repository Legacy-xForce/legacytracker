package com.legacy.legacytracker

import com.legacy.legacytracker.tracking.TrackingChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var trackingChannel: TrackingChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        trackingChannel = TrackingChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        trackingChannel?.dispose()
        trackingChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
