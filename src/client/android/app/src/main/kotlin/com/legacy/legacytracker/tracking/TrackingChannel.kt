package com.legacy.legacytracker.tracking

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter bridge for the UI engine. The engine works without it; this only
 * lets Dart configure it, read its status and receive live fixes while the
 * app is on screen.
 */
class TrackingChannel(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    TrackingEngine.Listener {

    private val appContext = context.applicationContext
    private val engine = TrackingEngine.get(appContext)
    private val methods = MethodChannel(messenger, "legacytracker/tracking")
    private val events = EventChannel(messenger, "legacytracker/tracking/events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                val baseUrl = call.argument<String>("baseUrl")
                val authHeader = call.argument<String>("authHeader")
                val userId = call.argument<String>("userId")
                val batterySaver = call.argument<Boolean>("batterySaver") ?: false
                val deviceId = call.argument<String>("deviceId")
                if (baseUrl == null || authHeader == null || userId == null) {
                    result.error("bad_args", "baseUrl, authHeader and userId are required", null)
                    return
                }
                reply(result) { engine.configure(baseUrl, authHeader, userId, batterySaver, deviceId) }
            }
            "start" -> reply(result) { engine.start() }
            "stop" -> {
                val clearData = call.argument<Boolean>("clearData") ?: false
                reply(result) { engine.stop(clearData) }
            }
            "setAppVisible" -> {
                val visible = call.argument<Boolean>("visible") ?: false
                reply(result) { engine.setAppVisible(visible) }
            }
            "flush" -> reply(result) { engine.flush() }
            "status" -> reply(result) { engine.status() }
            "logs" -> {
                val limit = call.argument<Int>("limit") ?: 300
                reply(result) { engine.logs(limit) }
            }
            "clearLogs" -> reply(result) { engine.store.clearLogs() }
            "log" -> {
                val category = call.argument<String>("category") ?: "app"
                val message = call.argument<String>("message") ?: ""
                reply(result) { engine.log(category, message) }
            }
            else -> result.notImplemented()
        }
    }

    /** Runs on the engine thread; replies on the platform thread as Flutter requires. */
    private fun reply(result: MethodChannel.Result, block: () -> Any?) {
        engine.post {
            val value = try {
                block()
            } catch (e: Exception) {
                main.post { result.error("engine_error", e.message, null) }
                return@post
            }
            main.post { result.success(if (value is Unit) null else value) }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        engine.listener = this
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        if (engine.listener === this) engine.listener = null
    }

    override fun onEngineEvent(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    fun dispose() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        if (engine.listener === this) engine.listener = null
        sink = null
    }
}
