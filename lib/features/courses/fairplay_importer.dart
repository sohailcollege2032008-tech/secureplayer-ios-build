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

    await _writeCompatibilityMarker(lectureId, metadata);

    return lectureId;
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
    // never otherwise read for a genuinely FairPlay lecture.
    if (await markerFile.exists()) return;
    await courseDir.create(recursive: true);
    await markerFile.writeAsString(jsonEncode({
      'format_version': '1.0-fairplay-marker',
      'lecture_id': lectureId,
      'course_id': metadata['course_id'] ?? lectureId,
      'title': metadata['title'] ?? lectureId,
      'file_iv_map': <String, String>{},
      'files': <Map<String, dynamic>>[],
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
}
