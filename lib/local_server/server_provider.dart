import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../core/constants/server_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/device_id_util.dart';
import '../security_layer/adb_detection/adb_detection_service.dart';
import '../security_layer/secure_storage/secure_storage_provider.dart';
import 'decryption/iv_map_crypto.dart';
import 'shelf_server.dart';

/// Args passed when starting the shelf server for a single video in a lecture.
@immutable
class VideoPlaybackArgs {
  const VideoPlaybackArgs({
    required this.lectureId,
    required this.videoId,
    this.watermarkEnabled = true,
  });

  final String lectureId;
  final String videoId;
  final bool watermarkEnabled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoPlaybackArgs &&
          other.lectureId == lectureId &&
          other.videoId == videoId &&
          other.watermarkEnabled == watermarkEnabled);

  @override
  int get hashCode => Object.hash(lectureId, videoId, watermarkEnabled);
}

@immutable
class VideoServerReady {
  const VideoServerReady({
    required this.port,
    required this.sessionToken,
    required this.hlsUrl,
    required this.adbDetected,
  });

  final int port;
  final String sessionToken;
  final String hlsUrl;
  final bool adbDetected;
}

class VideoServerNotifier extends AutoDisposeFamilyAsyncNotifier<
    VideoServerReady, VideoPlaybackArgs> {
  HttpServer? _server;

  @override
  Future<VideoServerReady> build(VideoPlaybackArgs arg) async {
    ref.onDispose(() {
      _server?.close(force: true);
      _server = null;
    });

    return _startup(arg).timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw const VideoStartupTimeoutException(
        'Video took too long to start. Tap Retry.',
      ),
    );
  }

  Future<VideoServerReady> _startup(VideoPlaybackArgs arg) async {
    final adb = await AdbDetectionService().checkAdb();
    if (adb.blocking) {
      throw const AdbDetectedException(
        'USB debugging detected. Disable Developer Options to play.',
      );
    }

    // Ensure the decrypt isolate is warm before the player requests segments,
    // so the very first video doesn't stall on the isolate cold start. No-op
    // (returns instantly) once warmed earlier from main().
    await warmUpSegmentDecryptor();

    final storage = ref.read(secureStorageProvider);
    // Key is stored under lectureId in v2
    final keyHex = await storage.getKey(arg.lectureId);
    if (keyHex == null) {
      throw KeyNotFoundException(
        'No decryption key found for lecture "${arg.lectureId}". Please re-import.',
      );
    }

    final appDir = await getApplicationSupportDirectory();
    final deviceId = await DeviceIdUtil.getDeviceId();
    final token = _generateToken();

    // Build watermark text server-side only when watermark is enabled.
    // Passing empty string to htmlHandler disables the overlay injection.
    final watermarkText =
        arg.watermarkEnabled ? await _buildWatermarkText() : '';

    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final actualPort = httpServer.port;

    final lectureDir = '${appDir.path}/courses/${arg.lectureId}';
    final fileIvMap = _readFileIvMap(lectureDir);

    final handler = buildShelfHandler(
      lectureId: arg.lectureId,
      actualPort: actualPort,
      lectureDir: lectureDir,
      keyHex: keyHex,
      deviceId: deviceId,
      appDocPath: appDir.path,
      sessionToken: token,
      fileIvMap: fileIvMap,
      watermarkText: watermarkText,
    );

    shelf_io.serveRequests(httpServer, handler);
    _server = httpServer;

    return VideoServerReady(
      port: actualPort,
      sessionToken: token,
      hlsUrl: 'http://${ServerConstants.localhost}:$actualPort'
          '/playlist/${arg.lectureId}/${arg.videoId}',
      adbDetected: adb.detected,
    );
  }

  static Map<String, String> _readFileIvMap(String lectureDir) {
    try {
      final metaFile = File('$lectureDir/metadata.json');
      if (!metaFile.existsSync()) return const {};
      final json = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
      final raw = json['file_iv_map'] as Map<String, dynamic>? ?? {};
      return raw.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return const {};
    }
  }

  static Future<String> _buildWatermarkText() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return 'SECURE PLAYER';
      const storage = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );
      final name = await storage.read(key: 'student_name_${user.uid}') ?? '';
      final phone = await storage.read(key: 'student_phone_${user.uid}') ?? '';
      final parts = <String>[
        if (name.isNotEmpty) name,
        if (phone.isNotEmpty) phone,
      ];
      return parts.isEmpty ? 'SECURE PLAYER' : parts.join(' - ');
    } catch (_) {
      return 'SECURE PLAYER';
    }
  }

  static String _generateToken() {
    final rand = Random.secure();
    return List.generate(16, (_) => rand.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

final videoServerProvider = AsyncNotifierProvider.autoDispose
    .family<VideoServerNotifier, VideoServerReady, VideoPlaybackArgs>(
  VideoServerNotifier.new,
);
