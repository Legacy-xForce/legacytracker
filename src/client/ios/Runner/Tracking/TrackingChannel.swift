import Flutter
import Foundation

// MARK: - Flutter bridge

/// Method/event channels for the UI engine (see tracking_engine.dart).
final class TrackingChannel: NSObject, FlutterStreamHandler {
    private let methods: FlutterMethodChannel
    private let events: FlutterEventChannel
    private var sink: FlutterEventSink?

    init(messenger: FlutterBinaryMessenger) {
        methods = FlutterMethodChannel(name: "legacytracker/tracking", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "legacytracker/tracking/events", binaryMessenger: messenger)
        super.init()
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        events.setStreamHandler(self)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let engine = TrackingEngine.shared
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "configure":
            guard let baseUrl = args["baseUrl"] as? String,
                  let authHeader = args["authHeader"] as? String,
                  let userId = args["userId"] as? String else {
                result(FlutterError(code: "bad_args", message: "baseUrl, authHeader and userId are required", details: nil))
                return
            }
            engine.configure(baseUrl: baseUrl, authHeader: authHeader, userId: userId,
                             batterySaver: args["batterySaver"] as? Bool ?? false)
            result(nil)
        case "start":
            engine.start()
            result(nil)
        case "stop":
            engine.stop(clearData: args["clearData"] as? Bool ?? false) { result(nil) }
        case "setAppVisible":
            engine.setAppVisible(args["visible"] as? Bool ?? false)
            result(nil)
        case "flush":
            engine.flush()
            result(nil)
        case "status":
            result(engine.status())
        case "logs":
            result(engine.logs(limit: args["limit"] as? Int ?? 300))
        case "clearLogs":
            engine.store.clearLogs()
            result(nil)
        case "log":
            engine.log(args["category"] as? String ?? "app", args["message"] as? String ?? "")
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        TrackingEngine.shared.listener = { [weak self] event in self?.sink?(event) }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        TrackingEngine.shared.listener = nil
        return nil
    }
}
