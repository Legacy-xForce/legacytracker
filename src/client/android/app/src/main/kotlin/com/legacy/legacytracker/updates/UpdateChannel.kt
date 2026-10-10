package com.legacy.legacytracker.updates

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Flutter bridge for [AppUpdater]: configuration, status, and the manual buttons. */
class UpdateChannel(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private val appContext = context.applicationContext
    private val updater = AppUpdater.get(appContext)
    private val methods = MethodChannel(messenger, "legacytracker/updates")
    private val events = EventChannel(messenger, "legacytracker/updates/events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val onChange: () -> Unit = { main.post { sink?.success(updater.status()) } }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                val baseUrl = call.argument<String>("baseUrl")
                if (baseUrl == null) {
                    result.error("bad_args", "baseUrl is required", null)
                    return
                }
                reply(result) { updater.configure(baseUrl) }
            }
            // Cheap, and must not wait behind a download on the updater thread.
            "status" -> result.success(updater.status())
            "check" -> reply(result) {
                // Failures land in the status' lastError.
                try {
                    updater.check()
                } catch (e: Exception) {
                    updater.recordError(e)
                }
                updater.status()
            }
            "install" -> reply(result) {
                try {
                    updater.install("installed from the app")
                } catch (e: Exception) {
                    updater.recordError(e)
                }
                updater.status()
            }
            "openInstallSettings" -> {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${appContext.packageName}"))
                } else {
                    Intent(Settings.ACTION_SECURITY_SETTINGS)
                }
                appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Runs on the updater's thread (network, disk); replies on the platform thread. */
    private fun reply(result: MethodChannel.Result, block: () -> Any?) {
        updater.executor.execute {
            val value = try {
                block()
            } catch (e: Exception) {
                main.post { result.error("update_error", e.message, null) }
                return@execute
            }
            main.post { result.success(if (value is Unit) null else value) }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        updater.listener = onChange
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        if (updater.listener === onChange) updater.listener = null
    }

    fun dispose() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        onCancel(null)
    }
}
