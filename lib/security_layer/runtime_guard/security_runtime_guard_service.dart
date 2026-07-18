import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_windowmanager/flutter_windowmanager.dart';

import '../adb_detection/adb_detection_service.dart';
import '../root_detection/root_detection_service.dart';
import '../screen_protection/screen_protection_provider.dart';
import 'security_guard_state.dart';

/// Single source of truth for "is it safe to show decrypted content right
/// now", shared by every screen that renders it (video, file, quiz, review).
/// Ref-counted so the native checks and the event subscription only run
/// while at least one protected screen is actually mounted.
///
/// Fully inert in debug builds — matching every other check in
/// security_layer/ (RootDetectionService, AdbDetectionService.checkAdb,
/// ScreenProtectionService.enable all already short-circuit on kDebugMode).
/// Without this, ADB being enabled (true for essentially every `flutter run`
/// debug session) or FLAG_SECURE never being applied in debug (screen
/// protection itself no-ops there) would each trip a permanent, no-escape
/// block screen and make the app unusable for development. [debugModeOverride]
/// exists only so tests can exercise the release-mode logic without needing
/// an actual release build.
class SecurityRuntimeGuardController extends StateNotifier<SecurityGuardState> {
  SecurityRuntimeGuardController(
    this._ref, {
    AdbDetectionService? adbService,
    RootDetectionService? rootService,
    bool? debugModeOverride,
  })  : _adbService = adbService ?? AdbDetectionService(),
        _rootService = rootService ?? RootDetectionService(),
        _debugMode = debugModeOverride ?? kDebugMode,
        super(const SecurityGuardClear()) {
    // Registered once for the provider's lifetime (Riverpod manages the
    // subscription itself) — _onEvent no-ops while _refCount is 0 (or in
    // debug), so this costs nothing while no protected screen is mounted.
    _ref.listen<AsyncValue<String>>(securityEventsProvider, (_, next) {
      next.whenData(_onEvent);
    });
  }

  final Ref _ref;
  final AdbDetectionService _adbService;
  final RootDetectionService _rootService;
  final bool _debugMode;
  static const _secChannel = MethodChannel('secureplayer/security');

  static const _androidInterval = Duration(seconds: 5);
  // Windows' Frida check spawns powershell.exe twice (up to ~4s wall-clock).
  // Running that every few seconds would itself spawn dozens of visible
  // processes a minute. The native WM_ACTIVATE focus signal (see
  // _onEvent's 'focus_gained' case) handles the near-instant case; this
  // tick only needs to catch an already-attached, persistently-foregrounded
  // session, so it can afford to be much less frequent.
  static const _windowsInterval = Duration(seconds: 25);

  Timer? _periodicTimer;
  int _refCount = 0;

  bool _externalDisplayActive = false;
  bool _recordingActive = false;
  bool _focusLost = false;
  bool get _hasTransientCause =>
      _externalDisplayActive || _recordingActive || _focusLost;

  void activate() {
    if (_debugMode) return;
    _refCount++;
    if (_refCount > 1) return; // already running for another screen
    _periodicTimer = Timer.periodic(
      Platform.isWindows ? _windowsInterval : _androidInterval,
      (_) => recheckNow(),
    );
    recheckNow();
  }

  void deactivate() {
    if (_debugMode) return;
    if (_refCount == 0) return;
    _refCount--;
    if (_refCount > 0) return;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _externalDisplayActive = false;
    _recordingActive = false;
    _focusLost = false;
  }

  void _onEvent(String event) {
    if (_debugMode || _refCount == 0) return; // no protected screen mounted — ignore
    switch (event) {
      case 'hdmi_connected':
        _externalDisplayActive = true;
        _applyTransientOrRecheck();
      case 'hdmi_disconnected':
        _externalDisplayActive = false;
        _applyTransientOrRecheck();
      case 'recording_started':
        _recordingActive = true;
        _applyTransientOrRecheck();
      case 'recording_stopped':
        _recordingActive = false;
        _applyTransientOrRecheck();
      case 'focus_lost':
        _focusLost = true;
        _applyTransientOrRecheck();
      case 'focus_gained':
        _focusLost = false;
        // Re-verify immediately — this is the mechanism that catches a
        // Settings popup (or any other overlay) opening and closing without
        // the app ever fully backgrounding.
        recheckNow();
    }
  }

  void _applyTransientOrRecheck() {
    if (state is SecurityGuardViolation) return; // a real violation outranks this
    if (_hasTransientCause) {
      state = const SecurityGuardTransientHold();
    } else {
      recheckNow();
    }
  }

  /// Runs the full check set immediately. Called on activation, on every
  /// periodic tick, and the instant focus returns. No-ops in debug builds.
  Future<void> recheckNow() async {
    if (_debugMode) return;

    final adb = await _adbService.checkAdbDetailed();
    if (adb.adbEnabled) return _violate(SecurityGuardReason.adbEnabled);
    if (adb.developerOptionsEnabled) {
      return _violate(SecurityGuardReason.developerOptionsEnabled);
    }
    if (adb.emulatorDetected) {
      return _violate(SecurityGuardReason.emulatorDetected);
    }
    if (adb.debuggableBuild) {
      return _violate(SecurityGuardReason.debuggableBuild);
    }

    switch (await _rootService.detectCause()) {
      case RootDetectionCause.rooted:
        return _violate(SecurityGuardReason.rooted);
      case RootDetectionCause.frida:
        return _violate(SecurityGuardReason.fridaDetected);
      case RootDetectionCause.xposed:
        return _violate(SecurityGuardReason.xposed);
      case RootDetectionCause.magiskHidden:
        return _violate(SecurityGuardReason.magiskHidden);
      case RootDetectionCause.signatureInvalid:
        return _violate(SecurityGuardReason.signatureInvalid);
      case RootDetectionCause.virtualMachine:
        return _violate(SecurityGuardReason.virtualMachineDetected);
      case RootDetectionCause.debuggerAttached:
        return _violate(SecurityGuardReason.debuggerAttached);
      case RootDetectionCause.none:
        break;
    }

    if (Platform.isAndroid && await _flagSecureMissingAfterHeal()) {
      return _violate(SecurityGuardReason.flagSecureMissing);
    }

    state = _hasTransientCause
        ? const SecurityGuardTransientHold()
        : const SecurityGuardClear();
  }

  void _violate(SecurityGuardReason reason) {
    state = SecurityGuardViolation(reason);
  }

  // Verifies FLAG_SECURE is still applied and proactively re-applies it if
  // not (a patched ROM or Xposed module could clear it silently) — mirrors
  // the self-heal behavior the two screens used to do individually.
  Future<bool> _flagSecureMissingAfterHeal() async {
    try {
      final flags = await _secChannel.invokeMethod<int>('getWindowFlags') ?? 0;
      const flagSecureBit = 0x00002000;
      final missing = (flags & flagSecureBit) == 0;
      if (missing) {
        await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
      }
      return missing;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    super.dispose();
  }
}

final securityRuntimeGuardProvider =
    StateNotifierProvider<SecurityRuntimeGuardController, SecurityGuardState>(
  (ref) => SecurityRuntimeGuardController(ref),
);
