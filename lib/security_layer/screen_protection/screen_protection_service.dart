import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_windowmanager/flutter_windowmanager.dart';
import 'package:win32/win32.dart'
    show
        GetForegroundWindow,
        GetSystemMetrics,
        SetWindowDisplayAffinity,
        SM_CMONITORS,
        WDA_EXCLUDEFROMCAPTURE;

class ScreenProtectionService {
  static const _methodChannel = MethodChannel('secureplayer/security');
  static const _eventChannel = EventChannel('secureplayer/security_events');

  // ── Windows state ──────────────────────────────────────────────────────────
  Timer? _protectionTimer;
  Timer? _hdmiTimer;
  StreamSubscription<dynamic>? _windowsNativeEventSubscription;
  final _externalDisplayController = StreamController<String>.broadcast();
  int _baseMonitorCount = 1;
  int _lastMonitorCount = 1;

  Future<void> enable() async {
    if (kDebugMode) return; // screenshots allowed in debug builds
    if (Platform.isAndroid) {
      await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
      try {
        final flags =
            await _methodChannel.invokeMethod<int>('getWindowFlags') ?? 0;
        if (flags & 0x00002000 == 0) {
          debugPrint(
              '[ScreenProtection] WARNING: FLAG_SECURE not confirmed in window flags');
        }
      } catch (_) {}
    } else if (Platform.isWindows) {
      _applyWindowsDisplayAffinity();
      // GetForegroundWindow() returns 0 if the app window isn't in the
      // foreground yet at startup. Re-apply after the window is rendered.
      Future.delayed(const Duration(milliseconds: 500), _applyWindowsDisplayAffinity);
      Future.delayed(const Duration(seconds: 1), _applyWindowsDisplayAffinity);
      _startWindowsProtectionTimer();
      _baseMonitorCount = _getMonitorCount();
      _lastMonitorCount = _baseMonitorCount;
      _hdmiTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final current = _getMonitorCount();
        if (current > _baseMonitorCount) {
          _externalDisplayController.add('hdmi_connected');
        } else if (current < _lastMonitorCount) {
          _externalDisplayController.add('hdmi_disconnected');
        }
        _lastMonitorCount = current;
      });
      // Forward the native WM_ACTIVATE-derived focus_lost/focus_gained
      // events (see windows/runner/security_event_channel.*) into the same
      // broadcast stream as the HDMI events above — one unified stream for
      // Windows, same as Android's single EventChannel-backed stream.
      _windowsNativeEventSubscription =
          _eventChannel.receiveBroadcastStream().listen(
        (e) => _externalDisplayController.add(e.toString()),
        onError: (_) {},
      );
    }
  }

  Future<void> disable() async {
    if (Platform.isAndroid) {
      try {
        await FlutterWindowManager.clearFlags(FlutterWindowManager.FLAG_SECURE);
      } catch (_) {}
    }
  }

  void dispose() {
    _protectionTimer?.cancel();
    _hdmiTimer?.cancel();
    _windowsNativeEventSubscription?.cancel();
    _externalDisplayController.close();
  }

  void _applyWindowsDisplayAffinity() {
    try {
      final hwnd = GetForegroundWindow();
      if (hwnd != 0) {
        // WDA_EXCLUDEFROMCAPTURE = 0x11 — window is excluded from screen capture
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
      }
    } catch (_) {}
  }

  void _startWindowsProtectionTimer() {
    _protectionTimer?.cancel();
    _protectionTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _applyWindowsDisplayAffinity();
    });
  }

  // Win32 API — no subprocess, no AV trigger. SM_CMONITORS = number of displays.
  static int _getMonitorCount() {
    try {
      return GetSystemMetrics(SM_CMONITORS);
    } catch (_) {
      return 1;
    }
  }

  /// Broadcast stream of security event strings.
  /// Android/iOS: forwarded directly from the native EventChannel.
  /// Windows: HDMI connect/disconnect from polling, merged with
  /// focus_lost/focus_gained forwarded from the native EventChannel above.
  Stream<String> get securityEvents => (Platform.isAndroid || Platform.isIOS)
      ? _eventChannel.receiveBroadcastStream().map((e) => e.toString())
      : _externalDisplayController.stream;
}
