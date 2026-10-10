package com.legacy.legacytracker.updates

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import androidx.core.content.IntentCompat

/** PackageInstaller's verdict on an update commit (see AppUpdater.install). */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_STATUS) return
        AppUpdater.get(context).onInstallStatus(
            status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE),
            versionCode = intent.getLongExtra(EXTRA_VERSION_CODE, 0L),
            message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE),
            confirm = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java),
        )
    }

    companion object {
        const val ACTION_STATUS = "com.legacy.legacytracker.updates.INSTALL_STATUS"
        const val EXTRA_VERSION_CODE = "version_code"
    }
}
