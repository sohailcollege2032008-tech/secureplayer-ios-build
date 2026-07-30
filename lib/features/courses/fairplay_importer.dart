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

    return lectureId;
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
