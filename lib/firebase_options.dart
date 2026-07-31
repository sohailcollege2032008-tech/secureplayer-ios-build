import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return windows;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.windows:
        return windows;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions not configured for: $defaultTargetPlatform',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAlx6lPaXPd3qRxgxhqkXxp68WYskodQ0E',
    appId: '1:312422331227:android:6b95783d3a6d81c749e07e',
    messagingSenderId: '312422331227',
    projectId: 'stud-future-platform-db',
    storageBucket: 'stud-future-platform-db.firebasestorage.app',
  );

  // Reuses whitelabel-full's iOS Firebase app registration (same bundle ID,
  // com.mashrou3dactoor.player — see codemagic.yaml's ios-app-store-release
  // workflow doc for why: Osama's existing App Store Connect app can't have
  // its bundle ID changed once created, so this branch's own iOS build
  // reuses that same identity instead of registering a new one, while the
  // visible app name/branding stays "Secure Player" — see Info.plist.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBgIMJLNUmnUaWO-apL4KHpuiScj07i3e0',
    appId: '1:312422331227:ios:f194408a2d4cac3b49e07e',
    messagingSenderId: '312422331227',
    projectId: 'stud-future-platform-db',
    storageBucket: 'stud-future-platform-db.firebasestorage.app',
    iosBundleId: 'com.mashrou3dactoor.player',
  );

  // Registered as "teacher_studio (windows)" web app in Firebase Console
  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyAc-roqHin0njDn_65FOvYaEy1uGU_8Hcc',
    appId: '1:312422331227:web:1c75153c15a61b2f49e07e',
    messagingSenderId: '312422331227',
    projectId: 'stud-future-platform-db',
    storageBucket: 'stud-future-platform-db.firebasestorage.app',
    authDomain: 'stud-future-platform-db.firebaseapp.com',
  );
}
