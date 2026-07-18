import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'firebase_options.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/app.dart';
import 'core/services/firestore_rest.dart';
import 'core/services/quiz_db_service.dart';
import 'core/services/quiz_settings_service.dart';
import 'features/courses/sec_file_intent_service.dart';
import 'features/quiz/quiz_settings_provider.dart';
import 'local_server/decryption/iv_map_crypto.dart';
import 'security_layer/screen_protection/screen_protection_service.dart';

void _logError(String tag, Object error, StackTrace? stack) {
  debugPrint('[$tag] $error');
  if (stack != null) debugPrint('[$tag] $stack');
  if (Platform.isWindows) {
    _writeCrashLog(tag, error, stack);
    _reportCrashToFirestore(tag, error, stack);
  }
}

void _writeCrashLog(String tag, Object error, StackTrace? stack) {
  try {
    final logFile = File('${Platform.environment['TEMP'] ?? '.'}'
        '\\secureplayer_crash.log');
    final ts = DateTime.now().toIso8601String();
    final entry = '[$ts][$tag] $error\n${stack ?? ''}\n---\n';
    logFile.writeAsStringSync(entry, mode: FileMode.append);
  } catch (_) {}
}

// A repeating render/animation error has no natural ceiling on how many
// times it fires in one session — without a cap, that's an unbounded
// crash_reports write loop. Local file logging (_writeCrashLog) stays
// unconditional above; only the Firestore write is capped, so nothing is
// lost for on-machine debugging.
const _kMaxCrashReportsPerSession = 20;
final _reportedCrashSignatures = <String>{};
int _crashReportCount = 0;

void _reportCrashToFirestore(String tag, Object error, StackTrace? stack) {
  final signature = '$tag:${error.toString().substring(0, error.toString().length.clamp(0, 200))}';
  if (!_reportedCrashSignatures.add(signature)) return; // already seen this exact error
  if (_crashReportCount >= _kMaxCrashReportsPerSession) return;
  _crashReportCount++;

  FirestoreRest.instance.addDoc('crash_reports', {
    'timestamp': fsNow,
    'platform': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'tag': tag,
    'error': error.toString(),
    'stack_trace': stack?.toString() ?? '',
    'uid': FirebaseAuth.instance.currentUser?.uid,
    'app_version': '1.0.0',
  }).ignore();
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // SQLite FFI required on Windows/Linux (sqflite doesn't ship a native lib for desktop)
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // MediaKit must be initialized before any Player/Video widget is created (Desktop only)
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    MediaKit.ensureInitialized();
  }

  // Firebase must be initialized BEFORE accessing any Firebase service instance.
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Pre-open the SQLite quiz database so first quiz load is instant
  await QuizDbService.instance.init();

  // Created here (not later) so it can be seeded with provider state before
  // any widget exists — see quizSettingsProvider seeding below.
  final container = ProviderContainer();

  // Seed quizSettingsProvider synchronously before any widget can read it —
  // eliminates a race where QuizSettingsNotifier's own async _load() (from
  // SharedPreferences) hadn't resolved yet when quiz_screen.dart's initState()
  // did a synchronous read, silently defaulting shuffle/etc. back to off.
  final loadedQuizSettings = await QuizSettingsService.instance.load();
  container.read(quizSettingsProvider.notifier).seedFrom(loadedQuizSettings);

  // ── Error monitoring (after Firebase init — Crashlytics.instance is safe here) ──
  if (Platform.isAndroid) {
    // Always leave a local trace (logcat) before handing off to Crashlytics —
    // Crashlytics-only handling made on-device failures completely invisible,
    // which turned a throwing tap handler into a "button does nothing" bug.
    FlutterError.onError = (details) {
      debugPrint('SP_UNCAUGHT_FLUTTER: ${details.exception}\n${details.stack}');
      if (kDebugMode) FlutterError.presentError(details);
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      if (error is StateError &&
          error.message
              .contains('VideoPlayerController was used after being disposed')) {
        return true; // swallow BetterPlayer dispose race — harmless
      }
      debugPrint('SP_UNCAUGHT: $error\n$stack');
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } else {
    // Windows: write to local file + Firestore crash_reports collection.
    FlutterError.onError = (details) {
      _logError('SP_ERROR', details.exception, details.stack);
      if (kDebugMode) FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      if (error is StateError &&
          error.message
              .contains('VideoPlayerController was used after being disposed')) {
        return true;
      }
      _logError('SP_ASYNC', error, stack);
      return false;
    };
  }

  // Pre-warm the segment-decryptor isolate so the first video doesn't stall on
  // the one-time isolate/pointycastle cold start. Fire-and-forget — must not
  // delay launch; the await-guard in VideoServerNotifier._startup covers the
  // race where a video is opened before this completes.
  warmUpSegmentDecryptor();

  // Enable screen capture protection
  await ScreenProtectionService().enable();

  // Allow all orientations app-wide so device sensor controls rotation on every screen.
  if (Platform.isAndroid) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  // ── File intent bridge ───────────────────────────────────────────────────
  // Uses the top-level ProviderContainer (created above) so the handler is
  // active for the full app lifecycle — not just while CourseListScreen is
  // mounted.
  if (Platform.isAndroid) {
    const intentChannel = MethodChannel('secureplayer/file_intent');

    // Hot-start: .sec tapped while app is already open (onNewIntent)
    intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onSecFileReceived') {
        final path = call.arguments as String?;
        if (path != null) {
          container.read(pendingSecFileProvider.notifier).state = path;
        }
      }
    });

    // Cold-start: .sec was used to launch the app
    try {
      final path =
          await intentChannel.invokeMethod<String?>('getInitialSecFile');
      if (path != null) {
        container.read(pendingSecFileProvider.notifier).state = path;
      }
    } catch (_) {}
  } else if (Platform.isWindows) {
    // Windows has no intent system — a .sec/.secupdate file association just
    // launches the exe with the file path as a plain command-line argument.
    // There's no hot-start equivalent to Android's onNewIntent: each double-
    // click starts a new process, so cold-start is the only case here.
    for (final arg in args) {
      final lower = arg.toLowerCase();
      if (lower.endsWith('.sec') ||
          lower.endsWith('.secupdate') ||
          lower.endsWith('.secquiz')) {
        container.read(pendingSecFileProvider.notifier).state = arg;
        break;
      }
    }
  }

  runApp(
    ProviderScope(
      parent: container, // ignore: deprecated_member_use
      child: const SecurePlayerApp(),
    ),
  );
}
