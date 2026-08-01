import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';

/// App-wide keep-alive WebView session (the "browser memory" feature).
///
/// One controller per platform, created lazily on first use and REUSED by
/// every [HtmlFileViewer] — never destroyed when a screen closes. Within a
/// single app run this behaves like one Chrome tab: JS state, sessionStorage
/// and the HTTP cache survive leaving and re-entering any HTML file.
///
/// Across app restarts, persistence comes from two things:
///  1. a stable per-lecture server port (`ServerConstants.portFor`) so the
///     origin never changes → the platform's native WebView storage
///     (Android DOM storage, iOS WKWebsiteDataStore, Windows WebView2
///     profile under %LOCALAPPDATA%) keeps localStorage/cookies on disk;
///  2. nothing to do in code — storage lives on disk once the origin is
///     stable.
///
/// Security:
///  - The only wipe is on logout ([clearAll], attached via auth listener):
///    cache + cookies + navigate to about:blank, so a second student on the
///    same device starts clean.
///  - Screen close does NOT clear anything (that was the old behavior that
///    made quiz attempts vanish).
///  - HTTP responses stay `no-store` server-side, so decrypted file bytes
///    never linger in the on-disk cache — only browser *storage* persists.
class WebviewSession extends ChangeNotifier {
  WebviewSession._();

  static final WebviewSession instance = WebviewSession._();

  WebViewController? _androidController;

  WebviewController? _windowsController;
  bool _windowsReady = false;
  bool _windowsAvailable = true;
  Future<WebviewController?>? _windowsFuture;
  StreamSubscription<String?>? _windowsUrlSub;

  bool _authListenerAttached = false;

  bool get windowsReady => _windowsReady;
  bool get windowsAvailable => _windowsAvailable;
  WebviewController? get windowsController => _windowsController;

  /// Android (and iOS) controller — created synchronously on first use and
  /// kept for the app's lifetime. The navigation guard lives on the
  /// controller, so it applies to every reuse.
  WebViewController androidController() {
    return _androidController ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          if (req.url.startsWith('http://127.0.0.1:')) {
            return NavigationDecision.navigate;
          }
          // Open external http/https/mailto links in the system browser.
          final uri = Uri.tryParse(req.url);
          if (uri != null &&
              (uri.scheme == 'https' ||
                  uri.scheme == 'http' ||
                  uri.scheme == 'mailto')) {
            unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
          }
          return NavigationDecision.prevent;
        },
      ));
  }

  /// Lazily creates the Windows WebView2 controller (async init). Safe to
  /// call from multiple mounts: concurrent calls share the in-flight future,
  /// and every caller receives the ready controller to load its own URL.
  Future<WebviewController?> ensureWindowsController() {
    final existing = _windowsFuture;
    if (existing != null) return existing;
    return _windowsFuture = _createWindowsController();
  }

  Future<WebviewController?> _createWindowsController() async {
    // getWebViewVersion() returns null when WebView2 Runtime is not installed.
    final version = await WebviewController.getWebViewVersion();
    if (version == null) {
      _windowsAvailable = false;
      notifyListeners();
      return null;
    }

    final ctrl = WebviewController();
    await ctrl.initialize();
    await ctrl.setBackgroundColor(Colors.transparent);
    await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

    // Redirect any navigation that escapes 127.0.0.1 back to blank.
    // The HTML server-side JS injection also prevents link clicks, but
    // this provides a second layer for JavaScript redirects.
    _windowsUrlSub = _guardWindowsUrl(ctrl);

    _windowsController = ctrl;
    _windowsReady = true;
    notifyListeners();
    return ctrl;
  }

  /// Loads [url] into the keep-alive session. The auth header is a
  /// defense-in-depth extra on Android only — the URL's `?t=` query param
  /// is the real auth for every platform (Windows/iOS WebViews cannot send
  /// custom headers).
  void loadUrl(String url, {String? authToken}) {
    final windows = _windowsController;
    if (Platform.isWindows && windows != null && _windowsReady) {
      windows.loadUrl(url);
      return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      _androidController ??= androidController();
      _androidController!.loadRequest(
        Uri.parse(url),
        headers: {
          if (authToken != null) 'Authorization': 'Bearer $authToken',
        },
      );
    }
  }

  /// Wipes all browsing data. Called on logout so the next student starts
  /// clean; never called when a screen closes (that was the bug).
  Future<void> clearAll() async {
    final android = _androidController;
    if (android != null) {
      try {
        await android.clearCache();
      } catch (_) {}
      // clearCache() alone does NOT remove localStorage — verified against
      // webview_flutter_wkwebview 3.25.1, where clearCache() removes only
      // memoryCache/diskCache/offlineWebApplicationCache, and localStorage
      // is a separate WebsiteDataType reachable only via clearLocalStorage().
      // localStorage is exactly what this whole feature persists (quiz
      // answers), so without this call a shared device would hand the next
      // student the previous student's stored state after logout.
      try {
        await android.clearLocalStorage();
      } catch (_) {}
      try {
        await WebViewCookieManager().clearCookies();
      } catch (_) {}
      try {
        await android.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
    }
    final windows = _windowsController;
    if (windows != null) {
      try {
        await windows.clearCache();
      } catch (_) {}
      // Re-establish the navigation guard on a fresh subscription.
      await _windowsUrlSub?.cancel();
      _windowsUrlSub = _guardWindowsUrl(windows);
    }
  }

  StreamSubscription<String?> _guardWindowsUrl(WebviewController ctrl) {
    return ctrl.url.listen((url) {
      if (url.isNotEmpty &&
          url != 'about:blank' &&
          !url.startsWith('http://127.0.0.1:')) {
        ctrl.loadUrl('about:blank');
      }
    });
  }

  /// One-time listener: whenever the auth state drops to signed-out, wipe
  /// all browsing data. Attached from main() after Firebase init.
  void attachLogoutListener() {
    if (_authListenerAttached) return;
    _authListenerAttached = true;
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) clearAll();
    });
  }
}
