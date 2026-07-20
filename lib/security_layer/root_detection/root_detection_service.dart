import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_jailbreak_detection/flutter_jailbreak_detection.dart';
import 'package:win32/win32.dart' show IsDebuggerPresent;

/// Which specific check tripped, so callers that need to explain *why*
/// (the runtime security guard's block screen) don't have to re-run the
/// checks themselves or guess from a single collapsed bool.
enum RootDetectionCause {
  none,
  rooted,
  frida,
  xposed,
  magiskHidden,
  signatureInvalid,
  virtualMachine,
  debuggerAttached,
}

class RootDetectionService {
  static const _channel = MethodChannel('secureplayer/security');

  static const _skip =
      bool.fromEnvironment('SKIP_ROOT_CHECK', defaultValue: false);

  // TEMPORARY — added 2026-07-20 to unblock the client's TestFlight tester
  // who was hard-blocked on launch. Root cause was never conclusively
  // isolated to one of the 6 iOS checks below; build 128 fixed the one
  // known bug (isSignatureValid rejecting a clean TestFlight install), but
  // wasn't verified on-device before this override was requested. While
  // this is true, iOS ships with ZERO jailbreak/Frida/tamper protection —
  // Android is unaffected (detectCause()'s Android branch above is separate
  // and untouched). MUST be set back to false before any public App Store
  // release. Revert plan: flip to false, rebuild, hand the tester build 128
  // (or newer) and confirm it launches clean; only then remove this flag
  // and the early-return in _detectCauseIOS() entirely.
  static const _iosDetectionTemporarilyDisabled = true;

  // Obfuscated markers: frida, gum-js-loop, frida-agent, linjector, re.frida
  static final List<String> _fridaMarkers = [
    'ZnJpZGE=', 'Z3VtLWpzLWxvb3A=', 'ZnJpZGEtYWdlbnQ=', 'bGluamVjdG9y', 'cmUuZnJpZGE=',
  ].map((e) => utf8.decode(base64.decode(e))).toList();

  // Windows Registry keys for VM detection (Obfuscated)
  static final String _regVmware =
      utf8.decode(base64.decode('SEtMTVxtT0ZUV0FSRVxWTXdhcmUsIEluYy5cVk13YXJlIFRvb2xz'));
  static final String _regVbox =
      utf8.decode(base64.decode('SEtMTVxtT0ZUV0FSRVxPcmFjbGVcVmlydHVhbEJveCBHdWVzdCBBZGRpdGlvbnM='));
  static final String _regMsvm =
      utf8.decode(base64.decode('SEtMTVxtT0ZUV0FSRVxNaWNyb3NvZnRcVmlydHVhbCBNYWNoaW5lXEd1ZXN0XFBhcmFtZXRlcnM='));
  static final String _regVmmouse =
      utf8.decode(base64.decode('SEtMTVxtWVNURU1cQ29udHJvbFNldDAwMVxTZXJ2aWNlc1xWTU1PVVNF'));
  static final String _regVboxguest =
      utf8.decode(base64.decode('SEtMTVxtWVNURU1cQ29udHJvbFNldDAwMVxTZXJ2aWNlc1xWQm94R3Vlc3Q='));

  // Dart-side Frida detection via /proc/self/maps scan (Android/Linux only).
  // Independent of MethodChannels — bypassing requires patching libapp.so.
  Future<bool> _checkFridaInDart() async {
    try {
      // "/proc/self/maps" -> "L3Byb2Mvc2VsZi9tYXBz"
      final path = utf8.decode(base64.decode('L3Byb2Mvc2VsZi9tYXBz'));
      final maps = await File(path).readAsString();
      if (_fridaMarkers.any((m) => maps.toLowerCase().contains(m))) return true;
    } catch (_) {}
    return false;
  }

  // Windows Frida detection via named pipe and process list.
  // Each check is capped at 2 seconds so it never hangs app startup.
  Future<bool> _checkFridaOnWindows() async {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-command',
        r'Get-ChildItem \\.\pipe\ -ErrorAction SilentlyContinue | '
            r'Where-Object { $_.Name -like "*frida*" } | '
            r'Select-Object -First 1 -ExpandProperty Name',
      ]).timeout(
        const Duration(seconds: 2),
        onTimeout: () => ProcessResult(0, 1, '', ''),
      );
      if ((r.stdout as String).trim().isNotEmpty) return true;
    } catch (_) {}
    try {
      final r = await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-command',
        r'Get-Process -ErrorAction SilentlyContinue | '
            r'Where-Object { $_.Name -match "frida|gum-js" } | '
            r'Select-Object -First 1 -ExpandProperty Name',
      ]).timeout(
        const Duration(seconds: 2),
        onTimeout: () => ProcessResult(0, 1, '', ''),
      );
      if ((r.stdout as String).trim().isNotEmpty) return true;
    } catch (_) {}
    return false;
  }

  /// Runs the full platform-appropriate check set and returns *which* one
  /// tripped (or [RootDetectionCause.none] if clean). [isDeviceCompromised]
  /// and [isDeviceRooted] are thin boolean wrappers over this for callers
  /// that only need a yes/no (the one-shot app-startup gate).
  Future<RootDetectionCause> detectCause() async {
    if (Platform.isWindows) {
      if (_skip || kDebugMode) return RootDetectionCause.none;
      if (await _checkFridaOnWindows()) return RootDetectionCause.frida;
      if (_isWindowsDebuggerPresent()) return RootDetectionCause.debuggerAttached;
      if (await _isWindowsVm()) return RootDetectionCause.virtualMachine;
      return RootDetectionCause.none;
    }
    if (_skip) return RootDetectionCause.none;
    if (kDebugMode) return RootDetectionCause.none;
    if (Platform.isIOS) return _detectCauseIOS();
    if (!Platform.isAndroid) return RootDetectionCause.none;
    try {
      // 0. Dart-side Frida check (MethodChannel-independent, Android/Linux only)
      if (await _checkFridaInDart()) return RootDetectionCause.frida;

      // 1. flutter_jailbreak_detection (su binary, test-keys, Magisk patterns)
      if (await FlutterJailbreakDetection.jailbroken) {
        return RootDetectionCause.rooted;
      }

      // 2. Native su paths + Superuser.apk + which su
      if (await _channel.invokeMethod<bool>('isRooted') ?? false) {
        return RootDetectionCause.rooted;
      }

      // 3. Frida / objection / gadget
      if (await _channel.invokeMethod<bool>('isFridaDetected') ?? false) {
        return RootDetectionCause.frida;
      }

      // 4. Xposed / LSposed / LSPatch
      if (await _channel.invokeMethod<bool>('isXposedDetected') ?? false) {
        return RootDetectionCause.xposed;
      }

      // 5. Magisk hidden root (Shamiko bypass detection)
      if (await _channel.invokeMethod<bool>('isMagiskHidden') ?? false) {
        return RootDetectionCause.magiskHidden;
      }

      // 6. APK signature — only enforced in release
      if (!kDebugMode) {
        final sigValid =
            await _channel.invokeMethod<bool>('isSignatureValid') ?? false;
        if (!sigValid) return RootDetectionCause.signatureInvalid;
      }

      return RootDetectionCause.none;
    } catch (_) {
      return RootDetectionCause.frida; // fail closed (treat as compromised)
    }
  }

  Future<RootDetectionCause> _detectCauseIOS() async {
    if (_iosDetectionTemporarilyDisabled) return RootDetectionCause.none;
    try {
      // 1. flutter_jailbreak_detection (Cydia/Sileo paths, sandbox check,
      //    fork test — via IOSSecuritySuite under the hood)
      if (await FlutterJailbreakDetection.jailbroken) {
        return RootDetectionCause.rooted;
      }

      // 2. Native jailbreak file/path checks + sandbox-escape write test
      if (await _channel.invokeMethod<bool>('isRooted') ?? false) {
        return RootDetectionCause.rooted;
      }

      // 3. Frida — DYLD_INSERT_LIBRARIES env var, loaded-dylib scan, port probe
      if (await _channel.invokeMethod<bool>('isFridaDetected') ?? false) {
        return RootDetectionCause.frida;
      }

      // 4. Substrate/tweak-injection framework (iOS analog of Xposed)
      if (await _channel.invokeMethod<bool>('isXposedDetected') ?? false) {
        return RootDetectionCause.xposed;
      }

      // 5. Jailbreak-concealment tooling (iOS analog of hidden-root Magisk)
      if (await _channel.invokeMethod<bool>('isMagiskHidden') ?? false) {
        return RootDetectionCause.magiskHidden;
      }

      // 6. Provisioning-profile presence + bundle-ID consistency
      if (!kDebugMode) {
        final sigValid =
            await _channel.invokeMethod<bool>('isSignatureValid') ?? false;
        if (!sigValid) return RootDetectionCause.signatureInvalid;
      }

      return RootDetectionCause.none;
    } catch (_) {
      return RootDetectionCause.frida; // fail closed, same posture as Android
    }
  }

  bool _isWindowsDebuggerPresent() {
    try {
      return IsDebuggerPresent() != 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isWindowsVm() async {
    final vmKeys = [_regVmware, _regVbox, _regMsvm, _regVmmouse, _regVboxguest];
    for (final key in vmKeys) {
      try {
        final r = await Process.run('reg', ['query', key]);
        if (r.exitCode == 0) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<bool> isDeviceCompromised() async =>
      (await detectCause()) != RootDetectionCause.none;

  Future<bool> isDeviceRooted() => isDeviceCompromised();
}
