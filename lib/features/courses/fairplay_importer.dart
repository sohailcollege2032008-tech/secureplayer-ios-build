import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart' hide ZipFile;
import 'package:flutter_archive/flutter_archive.dart';
import 'package:path_provider/path_provider.dart';

import '../../security_layer/fairplay/fairplay_service.dart';

/// Imports a .secfp bundle (built by Studio's "Export for iOS (FairPlay)",
/// see encryptor/fairplay_bundle_builder.py) — the FairPlay counterpart to
/// SecImporter for .sec files. Deliberately separate: the two formats are
/// not interchangeable, and this one needs no key-fetch step at import time
/// (unlike .sec, where getCourseKey is called during import) — FairPlay
/// keys are fetched per-video, lazily, by getFairplayLicense the first time
/// that video is actually played (see FairplayContentKeyDelegate.swift).
///
/// Uses flutter_archive (native C++), never the pure-Dart archive package,
/// for the same reason SecImporter does — safe for large files, unlike
/// loading a multi-hundred-MB zip fully into the VM heap.
class FairplayImporter {
  /// Extracts filePath (a .secfp) to
  /// {appDocuments}/fairplay_lectures/{lectureId}/, matching the bundle's
  /// own internal layout. Returns the lectureId on success.
  static Future<String> importFromPath(String filePath) async {
    final metadata = await peekMetadata(filePath);
    final lectureId = metadata['lecture_id'] as String;

    final appDir = await getApplicationDocumentsDirectory();
    final destDir = Directory('${appDir.path}/fairplay_lectures/$lectureId');
    if (await destDir.exists()) {
      await destDir.delete(recursive: true);
    }
    await destDir.create(recursive: true);

    await ZipFile.extractToDirectory(
      zipFile: File(filePath),
      destinationDir: destDir,
    );

    await _discardPersistedContentKeys(lectureId);
    await _writeCompatibilityMarker(lectureId, metadata);

    return lectureId;
  }

  /// Deletes any FairPlay content key this device already persisted for
  /// this lecture.
  ///
  /// Every re-export from Studio generates a brand new content key and IV
  /// (see fairplay_packager.package_fairplay_hls) and overwrites the
  /// Firestore entry, so the bytes arriving here are encrypted under a key
  /// the device may not have. But FairplayContentKeyDelegate.swift
  /// short-circuits on `persistableContentKeyExistsOnDisk` and reuses the
  /// cached key without revalidating it, and nothing else in the app ever
  /// removes one — not lecture deletion, not re-import. A stale key would
  /// therefore be applied to freshly-encrypted content and fail to decrypt,
  /// looking exactly like broken DRM.
  ///
  /// This is a production bug, not just a testing nuisance: a teacher
  /// re-publishing a lecture would break playback for every student who had
  /// already watched it, with no way to recover short of reinstalling.
  /// Keys are named "{lectureId}_{videoId}-Key" (the skd:// asset id), so
  /// every video belonging to this lecture is matched by prefix.
  static Future<void> _discardPersistedContentKeys(String lectureId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final keyDir = Directory('${appDir.path}/.fairplay_keys');
    if (!await keyDir.exists()) return;
    await for (final entry in keyDir.list()) {
      if (entry is! File) continue;
      if (entry.uri.pathSegments.last.startsWith('${lectureId}_')) {
        await entry.delete();
      }
    }
  }

  /// Every "is this lecture imported?" check across the app (course lecture
  /// list's lock icon AND tap-gating, video_player_screen.dart's courseId
  /// lookup) is keyed off ONE thing: whether
  /// getApplicationSupportDirectory()/courses/{lectureId}/metadata.json
  /// exists — the .sec format's own marker, checked in ~4 separate places
  /// in enrolled_courses_provider.dart. A FairPlay-only import (no
  /// accompanying .sec) never touches that path or that directory at all
  /// by design (see the class doc), so without this, a successfully
  /// imported FairPlay lecture stays permanently shown as locked and
  /// un-tappable — this is exactly the bug that showed up on the first
  /// real test. Writing a minimal, compatible metadata.json here — instead
  /// of patching every call site that checks for it — keeps this fix in
  /// one place and makes FairPlay imports indistinguishable from .sec
  /// imports to every OTHER screen that only cares "is it imported".
  ///
  /// Must be a genuine format_version "2.1" document (not just some marker
  /// string) with a real `videos` list, because localCoursesProvider
  /// (courses_provider.dart) parses that list into one CourseMetadata per
  /// video — an earlier version of this marker omitted `videos` entirely,
  /// which made every video parse as videoId="" and get classified
  /// isFileOnly=true (CourseMetadata.isFileOnly: segmentCount==0 &&
  /// videoId.isEmpty), so CourseDetailScreen rendered only the empty
  /// "Files & Materials" section with no video row to tap — the lecture
  /// looked imported but had nothing playable in it. Caught on the second
  /// real test run, right after the first (isImported) bug was fixed.
  static Future<void> _writeCompatibilityMarker(
    String lectureId,
    Map<String, dynamic> metadata,
  ) async {
    final supportDir = await getApplicationSupportDirectory();
    final courseDir = Directory('${supportDir.path}/courses/$lectureId');
    final markerFile = File('${courseDir.path}/metadata.json');
    // Never overwrite a REAL .sec import's metadata (richer content: actual
    // file attachments, real file_iv_map) if this same lectureId happens to
    // also have one — this marker only needs to exist, its own content is
    // never otherwise read for a genuinely FairPlay lecture. Self-heals an
    // earlier broken marker shape that omitted `videos` entirely (see the
    // class doc above): a lectureId reaching FairplayImporter always came
    // from a real .secfp bundle, which always has >=1 video by construction
    // (server.py rejects an empty video list at export time), so an
    // existing marker with an empty `videos` list can only be that old
    // broken shape, never a legitimate file-only .sec lecture — safe to
    // overwrite in that one case, left alone otherwise.
    if (await markerFile.exists()) {
      try {
        final existing =
            jsonDecode(await markerFile.readAsString()) as Map<String, dynamic>;
        final existingVideos = existing['videos'] as List? ?? [];
        if (existingVideos.isNotEmpty) return;
      } catch (_) {
        return; // unreadable/foreign file — don't touch it
      }
    }
    await courseDir.create(recursive: true);
    final videos = (metadata['videos'] as List? ?? [])
        .map((v) => {'id': v['id'], 'title': v['title'] ?? ''})
        .toList();
    await markerFile.writeAsString(jsonEncode({
      'format_version': '2.1',
      'lecture_id': lectureId,
      'course_id': metadata['course_id'] ?? lectureId,
      'title': metadata['title'] ?? lectureId,
      'teacher_uid': metadata['teacher_uid'] ?? '',
      'created_at': metadata['created_at'] ?? DateTime.now().toIso8601String(),
      'total_duration_seconds': 0,
      'file_iv_map': <String, String>{},
      'files': <Map<String, dynamic>>[],
      'videos': videos,
    }));
  }

  /// Reads only metadata.json from the bundle without extracting segments —
  /// mirrors SecImporter.peekMetadata's approach (pure-Dart archive package
  /// is fine here since it's a single small JSON entry, not the full zip).
  static Future<Map<String, dynamic>> peekMetadata(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('metadata.json');
    if (entry == null) {
      throw const FormatException('metadata.json not found in .secfp bundle');
    }
    final content = utf8.decode(entry.content as List<int>);
    return jsonDecode(content) as Map<String, dynamic>;
  }

  /// Whether lectureId has already been imported — checked the same way
  /// FairplayService.hasLocalPackage() does, so both agree on what "already
  /// imported" means.
  static Future<bool> isAlreadyImported(String lectureId, String videoId) =>
      FairplayService.hasLocalPackage(lectureId, videoId);

  /// Re-runs _writeCompatibilityMarker for an already-extracted package,
  /// without re-downloading or re-extracting anything. Needed because
  /// course_list_screen.dart's auto-import flow skips importFromPath
  /// entirely once isAlreadyImported is true (correctly — no reason to
  /// re-fetch a 200+ MB bundle on every login), which means a device that
  /// already extracted a package under the old broken marker shape would
  /// otherwise never get the self-heal in _writeCompatibilityMarker to run
  /// again. The bundle's own top-level metadata.json is already sitting on
  /// disk from the original extraction (fairplay_lectures/{lectureId}/
  /// metadata.json — same layout importFromPath extracts into), so this is
  /// just a cheap local JSON read, no network involved.
  static Future<void> ensureCompatibilityMarker(String lectureId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final metaFile =
        File('${appDir.path}/fairplay_lectures/$lectureId/metadata.json');
    if (!await metaFile.exists()) return;
    try {
      final metadata =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      await _writeCompatibilityMarker(lectureId, metadata);
    } catch (_) {
      // Corrupt/foreign metadata.json — nothing safe to do here.
    }
  }
}
