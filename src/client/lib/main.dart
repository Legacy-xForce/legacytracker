import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'src/features/background/background_tracker.dart';

/// FCM background message handler — runs in a separate isolate when the app is
/// killed or in the background.  Must be a top-level function.
@pragma('vm:entry-point')
Future<void> _fcmBackgroundMessageHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    return;
  }

  final pacing = message.data['pacing'] as String?;
  if (pacing == null) return;

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('pacing_mode', pacing);

  if (await FlutterForegroundTask.isRunningService) {
    await BackgroundTracker.applyPacingMode(pacing);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Firebase — gracefully skipped if google-services.json / GoogleService-Info.plist
  // are not present in the native projects.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(_fcmBackgroundMessageHandler);
  } catch (_) {
    // Firebase not configured; FCM-driven pacing updates will be unavailable.
  }

  BackgroundTracker.initialize();

  runApp(App());
}
