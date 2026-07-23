import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';
import '../app/theme.dart';

/// Platform-aware HTML viewer widget.
///
/// - Android: uses `webview_flutter` (WebViewWidget).
/// - Windows: uses `webview_windows` (WebView2 / Edge).
///
/// Security properties:
/// - NavigationDelegate (Android) blocks all non-127.0.0.1 navigation.
/// - URL listener (Windows) redirects any external navigation to about:blank.
/// - Watermark overlay + anti-selection CSS/JS injected server-side by html_handler.dart.
/// - WebView cache is cleared on dispose.
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
  WebViewController? _androidCtrl;

  WebviewController? _windowsCtrl;
  bool _windowsReady = false;
  bool _windowsAvailable = true;
  StreamSubscription<String?>? _urlSub;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _initWindows();
    } else if (Platform.isAndroid) {
      _initAndroid();
    }
  }

  void _initAndroid() {
    _androidCtrl = WebViewController()
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
      ))
      ..loadRequest(
        Uri.parse(widget.url),
        headers: {'Authorization': 'Bearer ${widget.sessionToken}'},
      );
  }

  Future<void> _initWindows() async {
    // getWebViewVersion() returns null when WebView2 Runtime is not installed.
    final version = await WebviewController.getWebViewVersion();
    if (version == null) {
      if (mounted) setState(() => _windowsAvailable = false);
      return;
    }

    final ctrl = WebviewController();
    await ctrl.initialize();
    await ctrl.setBackgroundColor(Colors.transparent);
    await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

    // Redirect any navigation that escapes 127.0.0.1 back to blank.
    // The HTML server-side JS injection also prevents link clicks, but
    // this provides a second layer for JavaScript redirects.
    _urlSub = ctrl.url.listen((url) {
      if (url.isNotEmpty &&
          url != 'about:blank' &&
          !url.startsWith('http://127.0.0.1:')) {
        ctrl.loadUrl('about:blank');
      }
    });

    await ctrl.loadUrl(widget.url);
    _windowsCtrl = ctrl;
    if (mounted) setState(() => _windowsReady = true);
  }

  @override
  void didUpdateWidget(HtmlFileViewer old) {
    super.didUpdateWidget(old);
    if (old.url == widget.url) return;
    if (Platform.isAndroid) {
      _androidCtrl?.loadRequest(
        Uri.parse(widget.url),
        headers: {'Authorization': 'Bearer ${widget.sessionToken}'},
      );
    } else if (Platform.isWindows && _windowsReady) {
      _windowsCtrl?.loadUrl(widget.url);
    }
  }

  @override
  void dispose() {
    _urlSub?.cancel();
    if (Platform.isAndroid && _androidCtrl != null) {
      _androidCtrl!.clearCache();
      _androidCtrl!.loadRequest(Uri.parse('about:blank'));
    }
    _windowsCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return _buildWindows();
    if (Platform.isAndroid) return _buildAndroid();
    return const Center(
      child: Text(
        'HTML preview not supported on this platform.',
        style: TextStyle(color: Colors.white38, fontSize: 13),
      ),
    );
  }

  Widget _buildAndroid() {
    if (_androidCtrl == null) return const SizedBox.shrink();
    return WebViewWidget(controller: _androidCtrl!);
  }

  Widget _buildWindows() {
    if (!_windowsAvailable) {
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
    if (!_windowsReady) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.primary),
      );
    }
    // _windowsCtrl is always non-null when _windowsReady is true (set in _initWindows)
    return Webview(_windowsCtrl!);
  }
}
