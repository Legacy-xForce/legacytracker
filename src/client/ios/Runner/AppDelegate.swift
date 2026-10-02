import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var trackingChannel: TrackingChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // First, before Flutter: when iOS relaunches the app in the background
    // for a region exit / significant change / visit, the event is delivered
    // to the location manager that exists at launch — and no UI (so possibly
    // no Flutter engine) ever starts in that case.
    TrackingEngine.shared.bootstrap(launchOptions: launchOptions)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LegacyTrackingChannel") {
      trackingChannel = TrackingChannel(messenger: registrar.messenger())
    }
  }

  // Tracking commands from the server arrive as silent (content-available)
  // pushes; the engine handles them natively, then Flutter plugins
  // (firebase_messaging) still get the call as before.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    TrackingEngine.shared.handleRemoteNotification(userInfo)
    super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
  }
}
