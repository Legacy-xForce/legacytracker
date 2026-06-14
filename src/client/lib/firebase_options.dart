import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Firebase is not configured for web.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'Firebase is not configured for ${defaultTargetPlatform.name}.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCHw4qoK6yy_4DutIVcKG-4njgnxLfOZkQ',
    appId: '1:245407814324:android:47d7646b37ea5fd58ebde1',
    messagingSenderId: '245407814324',
    projectId: 'legacytracker-36ad9',
    storageBucket: 'legacytracker-36ad9.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDn_NjXvWcVa-BtJ-d4osBTwNtAoKnvW-U',
    appId: '1:245407814324:ios:1afbc74859f8b50e8ebde1',
    messagingSenderId: '245407814324',
    projectId: 'legacytracker-36ad9',
    storageBucket: 'legacytracker-36ad9.firebasestorage.app',
    iosBundleId: 'com.legacy.legacytracker',
  );
}
