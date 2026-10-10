package com.legacy.legacytracker

import android.content.Intent
import android.os.Bundle
import com.legacy.legacytracker.tracking.TrackingChannel
import com.legacy.legacytracker.updates.AppUpdater
import com.legacy.legacytracker.updates.UpdateChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var trackingChannel: TrackingChannel? = null
    private var updateChannel: UpdateChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) AppUpdater.get(this).onLaunchIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        AppUpdater.get(this).onLaunchIntent(intent)
    }

    // Self-updates close the app, so they wait until it is off screen.
    override fun onStart() {
        super.onStart()
        AppUpdater.foreground = true
    }

    override fun onStop() {
        AppUpdater.foreground = false
        AppUpdater.get(this).onAppBackgrounded()
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        trackingChannel = TrackingChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        updateChannel = UpdateChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        trackingChannel?.dispose()
        trackingChannel = null
        updateChannel?.dispose()
        updateChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
