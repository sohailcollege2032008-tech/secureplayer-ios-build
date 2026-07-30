import 'dart:convert';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../../core/utils/device_id_util.dart';

/// iOS-only. Wires FairPlay-packaged lectures (produced by Studio's "Export
/// for iOS (FairPlay)" + built via encryptor/fairplay_packager.py) into
/// better_player_plus's forked AVContentKeySession path
/// (vendor/better_player_plus — see FairplayContentKeyDelegate.swift).
///
/// Reuses the existing shelf-server (local_server/) that's already running
/// for every video, but only to make the package files HTTP-reachable —
/// AVPlayer/AVURLAsset cannot stream an HLS .m3u8 playlist from a local
/// file:// URL at all (a fundamental AVFoundation/HLS limitation, not
/// specific to FairPlay). No decryption happens in that HTTP layer: the
/// served bytes stay fully FairPlay-encrypted, exactly as they are on disk.
/// AVFoundation's own secure decode path is what actually decrypts them,
/// using the content key AVContentKeySession obtained.
class FairplayService {
  FairplayService._();

  /// Cloud Function endpoint FairplayContentKeyDelegate.swift POSTs SPCs to.
  /// Same project/region as every other Cloud Function this app calls.
  static const _ksmProxyUrl =
      'https://us-central1-stud-future-platform-db.cloudfunctions.net/getFairplayLicense';

  static Future<Directory> _fairplayLecturesRoot() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/fairplay_lectures');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Where a video's extracted FairPlay package lives (or would live).
  /// Matches the .secfp bundle's own internal layout exactly (metadata.json
  /// + videos/{videoId}/...) — the whole archive is extracted as-is by
  /// FairplayImporter, so this must mirror that structure, not invent a
  /// different one.
  static Future<Directory> packageDirFor(String lectureId, String videoId) async {
    final root = await _fairplayLecturesRoot();
    return Directory('${root.path}/$lectureId/videos/$videoId');
  }

  /// Whether this video has already been imported as a FairPlay package —
  /// the video_player_screen.dart branch point checks this before deciding
  /// whether to use the FairPlay path or the existing shelf-server path.
  static Future<bool> hasLocalPackage(String lectureId, String videoId) async {
    final dir = await packageDirFor(lectureId, videoId);
    return File('${dir.path}/master.m3u8').exists();
  }

  /// Copies the bundled FPS application certificate (public data — the
  /// private key never leaves the KSM) from the Flutter asset bundle to a
  /// real file the native AVContentKeySessionDelegate can read via
  /// Data(contentsOf:). Idempotent — skips the copy if already present.
  static Future<String> resolveCertificateFilePath() async {
    final appDir = await getApplicationSupportDirectory();
    final certFile = File('${appDir.path}/fps_certificate.bin');
    if (!await certFile.exists()) {
      final bytes = await rootBundle.load('assets/fairplay/fps_certificate.bin');
      await certFile.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }
    return certFile.path;
  }

  /// Builds the BetterPlayerDataSource for a FairPlay-packaged video.
  /// Throws StateError if no package or no signed-in user — callers should
  /// have already checked hasLocalPackage() before reaching this point.
  ///
  /// port/token come from the already-running local shelf server (started
  /// unconditionally for every video by videoServerProvider — see
  /// server_provider.dart). The manifest is served over http://127.0.0.1
  /// rather than read via file://, because AVPlayer/AVURLAsset cannot
  /// stream an HLS .m3u8 playlist directly from local disk at all — that's
  /// a fundamental AVFoundation/HLS limitation (confirmed by Apple
  /// engineering: "you can't get m3u8 from the local filesystem"), not a
  /// FairPlay-specific or Simulator-specific one. Surfaced as
  /// "CoreMediaErrorDomain error -12865" on the very first real playback
  /// attempt. The served bytes are still fully FairPlay-encrypted on the
  /// wire — nothing here weakens what AVContentKeySession protects.
  static Future<BetterPlayerDataSource> buildDataSource({
    required String lectureId,
    required String videoId,
    required String courseId,
    required int port,
    required String token,
  }) async {
    final packageDir = await packageDirFor(lectureId, videoId);
    final masterPlaylist = File('${packageDir.path}/master.m3u8');
    if (!await masterPlaylist.exists()) {
      throw StateError('No FairPlay package found for $lectureId/$videoId');
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Cannot build FairPlay data source: not signed in.');
    }
    final idToken = await user.getIdToken();
    if (idToken == null) {
      throw StateError('Cannot build FairPlay data source: no ID token.');
    }
    final deviceId = await DeviceIdUtil.getDeviceId();
    final certPath = await resolveCertificateFilePath();

    final config = jsonEncode({
      'ksmProxyUrl': _ksmProxyUrl,
      'idToken': idToken,
      'lectureId': lectureId,
      'videoId': videoId,
      'courseId': courseId,
      'deviceId': deviceId,
    });

    final manifestUrl =
        'http://127.0.0.1:$port/fairplay/$lectureId/$videoId/master.m3u8?t=$token';

    return BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      manifestUrl,
      videoFormat: BetterPlayerVideoFormat.hls,
      drmConfiguration: BetterPlayerDrmConfiguration(
        drmType: BetterPlayerDrmType.fairplay,
        certificateUrl: 'file://$certPath',
        offlineFairplayConfig: config,
      ),
    );
  }
}
