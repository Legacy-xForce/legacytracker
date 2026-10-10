import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'src/core/constants.dart';
import 'src/features/updates/app_updater.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Firebase is only needed to register this device's FCM token. Tracking
  // commands ("someone opened the map") are handled by the native tracking
  // engine directly, so no Dart background-message handler is registered —
  // that would boot a Flutter engine for every push.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    // Firebase not configured; live-mode pushes will be unavailable.
  }

  // Outside the Play Store the app updates itself; checks run natively in
  // the background from here on.
  unawaited(AppUpdater.configure(AppConstants.backendBaseUrl));

  runApp(App());
}
