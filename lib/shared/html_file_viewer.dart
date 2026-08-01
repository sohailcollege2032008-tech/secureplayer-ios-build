import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';
import 'webview_session.dart';

/// Platform-aware HTML viewer widget.
///
/// - Android/iOS: `webview_flutter` (WebViewWidget / WKWebView).
/// - Windows: `webview_windows` (WebView2 / Edge).
///
/// All platforms share ONE keep-alive session ([WebviewSession]) so the
/// in-app browser behaves like Chrome: localStorage, cookies, sessionStorage
/// and in-page state survive leaving the viewer and — thanks to the stable
/// per-lecture server port — even an app restart. The session is wiped only
/// on logout, never on screen close.
///
/// Security properties (carried on the session's controller):
/// - NavigationDelegate (Android/iOS) blocks all non-127.0.0.1 navigation.
/// - URL listener (Windows) redirects any external navigation to about:blank.
/// - Watermark overlay + anti-selection CSS/JS injected server-side by html_handler.dart.
class HtmlFileViewer extends StatefulWidget {
  const HtmlFileViewer({
    super.key,
    required this.url,
    required this.sessionToken,
  });

  /// Full URL including ?t={token}&wm={watermarkText} query params.
  final String url;

  /// Session token for Android Authorization header (redundant with ?t= but added for defense-in-depth).
  final String sessionToken;

  @override
  State<HtmlFileViewer> createState() => _HtmlFileViewerState();
}

class _HtmlFileViewerState extends State<HtmlFileViewer> {
  @override
  void initState() {
    super.initState();
    WebviewSession.instance.addListener(_onSessionChanged);
    _loadCurrent();
  }

  @override
  void didUpdateWidget(HtmlFileViewer old) {
    super.didUpdateWidget(old);
    if (old.url == widget.url) return;
    _loadCurrent();
  }

  @override
  void dispose() {
    WebviewSession.instance.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCurrent() async {
    if (Platform.isWindows) {
      final ctrl = await WebviewSession.instance.ensureWindowsController();
      if (ctrl == null) return; // WebView2 missing — build shows the error view.
      if (mounted) ctrl.loadUrl(widget.url);
    } else {
      WebviewSession.instance
          .loadUrl(widget.url, authToken: widget.sessionToken);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return _buildWindows();
    if (Platform.isAndroid || Platform.isIOS) return _buildMobile();
    return const Center(
      child: Text(
        'HTML preview not supported on this platform.',
        style: TextStyle(color: Colors.white38, fontSize: 13),
      ),
    );
  }

  Widget _buildMobile() {
    final session = WebviewSession.instance;
    return WebViewWidget(controller: session.androidController());
  }

  Widget _buildWindows() {
    final session = WebviewSession.instance;
    if (!session.windowsAvailable) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.web_asset_off_rounded, color: Colors.white38, size: 48),
              SizedBox(height: 12),
              Text(
                'HTML content requires Microsoft Edge WebView2.',
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                'WebView2 should have been installed with the app.\nIf missing, reinstall SecurePlayer.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (!session.windowsReady) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
      );
    }
    // _windowsController is always non-null when windowsReady is true.
    final ctrl = session.windowsController;
    if (ctrl == null) return const SizedBox.shrink();
    return Webview(ctrl);
  }
}
