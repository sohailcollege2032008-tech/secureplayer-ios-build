import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Breakdown of every condition the native `isAdbEnabled` check folds
/// together, so callers that need to explain *why* (the runtime security
/// guard's block screen) don't have to re-invoke the channel themselves.
class AdbCheckDetail {
  const AdbCheckDetail({
    required this.adbEnabled,
    required this.developerOptionsEnabled,
    required this.emulatorDetected,
    required this.debuggableBuild,
  });

  final bool adbEnabled;
  final bool developerOptionsEnabled;
  final bool emulatorDetected;
  final bool debuggableBuild;

  bool get any =>
      adbEnabled || developerOptionsEnabled || emulatorDetected || debuggableBuild;

  static const clear = AdbCheckDetail(
    adbEnabled: false,
    developerOptionsEnabled: false,
    emulatorDetected: false,
    debuggableBuild: false,
  );
}

class AdbDetectionService {
  static const _channel = MethodChannel('secureplayer/security');

  /// Returns whether ADB (USB or wireless) is currently active.
  /// In debug builds: detected=true shows a warning but does NOT block.
  /// In release builds: detected=true prevents the server from starting.
  Future<({bool detected, bool blocking})> checkAdb() async {
    if (!Platform.isAndroid) return (detected: false, blocking: false);
    try {
      final detected = (await _checkDetailed()).any;
      return (detected: detected, blocking: detected && !kDebugMode);
    } catch (_) {
      if (kDebugMode) return (detected: false, blocking: false);
      return (detected: true, blocking: true);
    }
  }

  /// Per-cause breakdown, used by the runtime security guard to show a
  /// cause-specific message instead of a generic "blocked" one.
  Future<AdbCheckDetail> checkAdbDetailed() async {
    if (!Platform.isAndroid) return AdbCheckDetail.clear;
    try {
      return await _checkDetailed();
    } catch (_) {
      // Fail closed: treat a broken channel the same as ADB being on.
      return const AdbCheckDetail(
        adbEnabled: true,
        developerOptionsEnabled: false,
        emulatorDetected: false,
        debuggableBuild: false,
      );
    }
  }

  Future<AdbCheckDetail> _checkDetailed() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('isAdbEnabled');
    if (raw == null) return AdbCheckDetail.clear;
    return AdbCheckDetail(
      adbEnabled: raw['adbEnabled'] as bool? ?? false,
      developerOptionsEnabled: raw['developerOptionsEnabled'] as bool? ?? false,
      emulatorDetected: raw['emulatorDetected'] as bool? ?? false,
      debuggableBuild: raw['debuggableBuild'] as bool? ?? false,
    );
  }
}
