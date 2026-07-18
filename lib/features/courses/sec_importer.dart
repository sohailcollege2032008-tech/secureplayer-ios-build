import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' hide ZipFile;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_archive/flutter_archive.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/errors/app_exception.dart';
import '../../core/models/course_metadata.dart';
import '../../core/models/lecture_metadata.dart';
import '../../core/services/cloud_function_http_client.dart';
import '../../core/services/firestore_rest.dart';
import '../../core/utils/device_id_util.dart';
import '../../local_server/decryption/iv_map_crypto.dart';
import '../../security_layer/secure_storage/secure_storage_service.dart';

enum ImportPhase { pickingFile, extracting, fetchingKey, securing, done }

class ImportProgress {
  const ImportProgress({
    required this.phase,
    this.securedSegments = 0,
    this.totalSegments = 0,
    this.currentVideoIndex = 0,
    this.totalVideos = 0,
  });

  final ImportPhase phase;
  final int securedSegments;
  final int totalSegments;
  final int currentVideoIndex;
  final int totalVideos;

  String get label {
    switch (phase) {
      case ImportPhase.pickingFile:
        return 'Selecting file...';
      case ImportPhase.extracting:
        return 'Extracting lecture...';
      case ImportPhase.fetchingKey:
        return 'Verifying access...';
      case ImportPhase.securing:
        if (totalVideos > 1) {
          return 'Securing video $currentVideoIndex of $totalVideos'
              ' ($securedSegments/$totalSegments segments)';
        }
        return 'Securing ($securedSegments/$totalSegments segments)';
      case ImportPhase.done:
        return 'Done!';
    }
  }

  double? get progress {
    if (phase == ImportPhase.securing && totalSegments > 0) {
      return securedSegments / totalSegments;
    }
    return null; // indeterminate
  }
}

typedef OnImportProgress = void Function(ImportProgress p);

class SecImporter {
  const SecImporter(this._storage);
  final SecureStorageService _storage;

  // True once a lecture/collection has fully finished importing — written as
  // the last step of a successful import. Checked up front so a repeat tap
  // of the same .sec/.secquiz (Telegram re-forwards, accidental double-taps,
  // retrying after an unrelated failure) skips straight to "done" instead of
  // wiping the local copy and re-calling getCourseKey. That redundant-call
  // pattern was the single largest driver of both Cloud Function cost and
  // errors in production before this guard existed.
  Future<bool> _alreadyImported(String appDocPath, String id) async {
    final marker = File('$appDocPath/courses/$id/.import_complete');
    return await marker.exists() && await _storage.hasKey(id);
  }

  Future<void> _markImportComplete(String appDocPath, String id) =>
      File('$appDocPath/courses/$id/.import_complete').writeAsString('');

  // General Quiz collections have no incremental-update mechanism (unlike
  // lectures, which have .secupdate) — every teacher edit requires a full
  // re-export under the SAME collection_id (confirmed stable across
  // re-exports; the AES key is also intentionally reused, never rotated,
  // per build_secquiz()'s own docstring). So the plain _alreadyImported()
  // guard above — correct and load-bearing for lectures, where it prevents
  // redundant re-decryption of potentially gigabytes of video — would
  // silently block every content update forever here: a teacher's
  // re-export would look identical (same id) to a student re-tapping the
  // same old file. Distinguish the two using metadata.json's `created_at`
  // (a fresh timestamp on every real export, unchanged on a re-tap/
  // re-forward of the same physical file): store it alongside the
  // existing marker, and only skip re-import when it matches what was
  // recorded last time.
  Future<bool> _quizCollectionUpToDate(
      String appDocPath, String id, String createdAt) async {
    final marker = File('$appDocPath/courses/$id/.import_complete');
    if (!await marker.exists() || !await _storage.hasKey(id)) return false;
    final storedCreatedAt = await marker.readAsString();
    return storedCreatedAt == createdAt;
  }

  Future<void> _markQuizCollectionImported(
          String appDocPath, String id, String createdAt) =>
      File('$appDocPath/courses/$id/.import_complete')
          .writeAsString(createdAt);

  Future<String> importSecFile({OnImportProgress? onProgress}) async {
    void report(ImportProgress p) => onProgress?.call(p);

    // ── 1. Pick file ─────────────────────────────────────────────────────────
    report(const ImportProgress(phase: ImportPhase.pickingFile));
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) {
      throw const ImportException('No file selected.');
    }
    final secPath = result.files.single.path!;

    // ── 2. Connectivity check ─────────────────────────────────────────────────
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.every((r) => r == ConnectivityResult.none)) {
      throw const ImportException(
          'No internet connection. Connect to import a lecture.');
    }

    // ── 3. Extract to temp dir ────────────────────────────────────────────────
    report(const ImportProgress(phase: ImportPhase.extracting));
    final appDir = await getApplicationSupportDirectory();
    // Use system temp dir (AppData\Local\Temp on Windows) — avoids OneDrive
    // sync locks and Windows Controlled Folder Access blocking Documents writes.
    final tmpBase = await getTemporaryDirectory();
    final tempDir = Directory('${tmpBase.path}/sp_import_temp');
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);
    // Pre-create files/ so flutter_archive can write encrypted file entries into
    // it even if it misidentifies the files/ directory entry in the ZIP (libzip
    // requires proper external_attr to recognise a directory — without it the
    // entry is treated as a zero-byte file and all files/{id} entries are dropped).
    await Directory('${tempDir.path}/files').create(recursive: true);

    try {
      await _extractSec(secPath, tempDir);
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Failed to extract .sec file: $e');
    }

    // ── 4. Parse metadata.json ────────────────────────────────────────────────
    final metadataFile = File('${tempDir.path}/metadata.json');
    if (!await metadataFile.exists()) {
      await tempDir.delete(recursive: true);
      throw const ImportException('Invalid .sec: metadata.json not found.');
    }

    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(await metadataFile.readAsString())
          as Map<String, dynamic>;
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Corrupt metadata.json: $e');
    }

    final version = meta['format_version'] as String? ?? '1.0';
    if (version == '2.0' || version == '2.1') {
      return _importV2(meta, tempDir, appDir.path, report);
    } else {
      return _importV1(meta, tempDir, appDir.path, report);
    }
  }

  // ── V2 Import ────────────────────────────────────────────────────────────

  Future<String> _importV2(
    Map<String, dynamic> meta,
    Directory tempDir,
    String appDocPath,
    OnImportProgress report,
  ) async {
    final LectureMetadata lecture;
    try {
      lecture = LectureMetadata.fromJson(meta);
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Invalid v2 metadata: $e');
    }

    final lectureId = lecture.lectureId;
    final courseId = lecture.courseId;

    if (await _alreadyImported(appDocPath, lectureId)) {
      await tempDir.delete(recursive: true);
      report(const ImportProgress(phase: ImportPhase.done));
      return lectureId;
    }

    final lectureDir = Directory('$appDocPath/courses/$lectureId');
    if (await lectureDir.exists()) await lectureDir.delete(recursive: true);
    await lectureDir.parent.create(recursive: true);
    await tempDir.rename(lectureDir.path);

    report(const ImportProgress(phase: ImportPhase.fetchingKey));
    final deviceId = await DeviceIdUtil.getDeviceId();
    late final String keyHex;
    try {
      final data = await _callCloudFunction('getCourseKey', {
        'lectureId': lectureId,
        'courseId': courseId,
        'deviceId': deviceId,
      });
      keyHex = data['keyHex'] as String;
      await _storage.storeKey(lectureId, keyHex);
    } on FirebaseFunctionsException catch (e) {
      await lectureDir.delete(recursive: true);
      throw KeyFetchException('Could not fetch key: ${e.code} — ${e.message}');
    } catch (e) {
      await lectureDir.delete(recursive: true);
      throw KeyFetchException('Key fetch failed: $e');
    }

    try {

      // Count total segments across all videos first for accurate progress
      final totalSegments =
          await _countSegmentsV2(lectureDir, lecture.videos.map((v) => v.id));
      int securedSoFar = 0;

      for (var i = 0; i < lecture.videos.length; i++) {
        final video = lecture.videos[i];
        securedSoFar = await _outerEncryptSegmentsV2(
          lectureDir: lectureDir,
          videoId: video.id,
          keyHex: keyHex,
          deviceId: deviceId,
          securedSoFar: securedSoFar,
          totalSegments: totalSegments,
          videoIndex: i + 1,
          totalVideos: lecture.videos.length,
          report: report,
        );
      }
    } catch (e) {
      await lectureDir.delete(recursive: true);
      await _storage.deleteKey(lectureId);
      throw ImportException('Device binding failed: $e');
    }

    await _markImportComplete(appDocPath, lectureId);
    report(const ImportProgress(phase: ImportPhase.done));
    return lectureId;
  }

  Future<int> _countSegmentsV2(
      Directory lectureDir, Iterable<String> videoIds) async {
    int total = 0;
    for (final videoId in videoIds) {
      final segDir =
          Directory('${lectureDir.path}/videos/$videoId/segments');
      if (await segDir.exists()) {
        total += segDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.ts'))
            .length;
      }
    }
    return total;
  }

  Future<int> _outerEncryptSegmentsV2({
    required Directory lectureDir,
    required String videoId,
    required String keyHex,
    required String deviceId,
    required int securedSoFar,
    required int totalSegments,
    required int videoIndex,
    required int totalVideos,
    required OnImportProgress report,
  }) async {
    final segDir =
        Directory('${lectureDir.path}/videos/$videoId/segments');
    if (!await segDir.exists()) return securedSoFar;

    final segments = segDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.ts'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in segments) {
      final original = await file.readAsBytes();
      // Encrypt in a background isolate so the UI thread stays responsive.
      final wrapped = await Isolate.run(
        () => encryptSegmentOuter(original, keyHex, deviceId),
      );
      await file.writeAsBytes(wrapped);
      securedSoFar++;
      report(ImportProgress(
        phase: ImportPhase.securing,
        securedSegments: securedSoFar,
        totalSegments: totalSegments,
        currentVideoIndex: videoIndex,
        totalVideos: totalVideos,
      ));
    }
    return securedSoFar;
  }

  // ── V1 Import ────────────────────────────────────────────────────────────

  Future<String> _importV1(
    Map<String, dynamic> meta,
    Directory tempDir,
    String appDocPath,
    OnImportProgress report,
  ) async {
    final CourseMetadata metadata;
    try {
      metadata = CourseMetadata.fromJson(meta);
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Invalid v1 metadata: $e');
    }

    final compoundId = metadata.compoundId;

    if (await _alreadyImported(appDocPath, compoundId)) {
      await tempDir.delete(recursive: true);
      report(const ImportProgress(phase: ImportPhase.done));
      return compoundId;
    }

    final courseDir = Directory('$appDocPath/courses/$compoundId');
    if (await courseDir.exists()) await courseDir.delete(recursive: true);
    await courseDir.parent.create(recursive: true);
    await tempDir.rename(courseDir.path);

    report(const ImportProgress(phase: ImportPhase.fetchingKey));
    final deviceId = await DeviceIdUtil.getDeviceId();
    late final String keyHex;
    late final Map<String, String> ivMap;
    try {
      final data = await _callCloudFunction('getCourseKey', {
        'lectureId': metadata.courseId,
        'courseId': metadata.courseId,
        'videoId': metadata.videoId,
        'deviceId': deviceId,
      });
      keyHex = data['keyHex'] as String;
      ivMap = Map<String, String>.from(data['ivMap'] as Map? ?? {});
      await _storage.storeKey(compoundId, keyHex);
    } on FirebaseFunctionsException catch (e) {
      await courseDir.delete(recursive: true);
      throw KeyFetchException('Could not fetch key: ${e.code} — ${e.message}');
    } catch (e) {
      await courseDir.delete(recursive: true);
      throw KeyFetchException('Key fetch failed: $e');
    }

    try {
      await _outerEncryptSegmentsV1(courseDir, keyHex, deviceId, report);
    } catch (e) {
      await courseDir.delete(recursive: true);
      await _storage.deleteKey(compoundId);
      throw ImportException('Device binding failed: $e');
    }

    final encryptedIvMap = encryptIvMap(ivMap, keyHex);
    await File('${courseDir.path}/iv_map.enc').writeAsBytes(encryptedIvMap);
    await File('${courseDir.path}/quizzes.json').writeAsString('[]');

    await _markImportComplete(appDocPath, compoundId);
    report(const ImportProgress(phase: ImportPhase.done));
    return compoundId;
  }

  Future<void> _outerEncryptSegmentsV1(
    Directory courseDir,
    String keyHex,
    String deviceId,
    OnImportProgress report,
  ) async {
    final segDir = Directory('${courseDir.path}/segments');
    if (!await segDir.exists()) return;
    final segments = segDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.ts'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final total = segments.length;
    for (var i = 0; i < segments.length; i++) {
      final file = segments[i];
      final original = await file.readAsBytes();
      final wrapped = await Isolate.run(
        () => encryptSegmentOuter(original, keyHex, deviceId),
      );
      await file.writeAsBytes(wrapped);
      report(ImportProgress(
        phase: ImportPhase.securing,
        securedSegments: i + 1,
        totalSegments: total,
        currentVideoIndex: 1,
        totalVideos: 1,
      ));
    }
  }

  // cloud_functions plugin has no Windows implementation — fall back to a
  // pinned raw-HTTP call (see core/services/cloud_function_http_client.dart).
  static Future<Map<String, dynamic>> _callCloudFunction(
    String name,
    Map<String, dynamic> payload,
  ) async {
    if (!Platform.isWindows) {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(name,
              options: HttpsCallableOptions(
                  timeout: const Duration(seconds: 20)));
      final resp = await callable.call(payload);
      return resp.data as Map<String, dynamic>;
    }
    return callCloudFunctionViaHttp(name, payload);
  }

  // ── Intent-based import (no file picker) ────────────────────────────────

  /// Reads only metadata.json from a .sec file without fully extracting it.
  /// Uses the pure-Dart archive package (safe for small JSON reads).
  static Future<Map<String, dynamic>> peekMetadata(String filePath) async {
    final file = File(filePath);
    final fileSize = await file.length();
    if (fileSize < 22) {
      throw ImportException(
          'File too small to be a valid .sec ($fileSize bytes). '
          'The download may be incomplete.');
    }
    final bytes = await file.readAsBytes();

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw ImportException(
          'Not a valid .sec archive: $e. '
          'The file may be corrupt or incompletely downloaded.');
    }

    // Primary lookup (exact name)
    ArchiveFile? entry = archive.findFile('metadata.json');
    // Fallback: some ZIP tools prefix entries with './' or a subdirectory
    if (entry == null) {
      for (final f in archive.files) {
        if (f.isFile &&
            (f.name == 'metadata.json' ||
                f.name.endsWith('/metadata.json'))) {
          entry = f;
          break;
        }
      }
    }

    if (entry == null || !entry.isFile) {
      final sample = archive.files
          .take(5)
          .map((f) => f.name)
          .join(', ');
      throw ImportException(
          'Invalid .sec: metadata.json not found '
          '(${archive.files.length} entries: $sample).');
    }
    try {
      return jsonDecode(utf8.decode(entry.content as List<int>))
          as Map<String, dynamic>;
    } catch (e) {
      throw ImportException('Corrupt metadata.json: $e');
    }
  }

  /// Returns true if the current user has an active enrollment for [courseId].
  static Future<bool> checkEnrollment(String courseId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    final docs = await FirestoreRest.instance.queryAnd(
      'enrollments',
      [
        (field: 'student_uid', op: 'EQUAL', value: user.uid),
        (field: 'course_id', op: 'EQUAL', value: courseId),
        (field: 'is_active', op: 'EQUAL', value: true),
      ],
      limit: 1,
    );
    return docs.isNotEmpty;
  }

  /// Import a .sec file from [filePath] (already on disk — skips file picker).
  /// Identical to [importSecFile] except for the file acquisition step.
  /// [filePath] is typically a temp cache file copied from the Android intent URI.
  Future<String> importFromPath(
    String filePath, {
    OnImportProgress? onProgress,
  }) async {
    void report(ImportProgress p) => onProgress?.call(p);

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.every((r) => r == ConnectivityResult.none)) {
      throw const ImportException(
          'No internet connection. Connect to import a lecture.');
    }

    report(const ImportProgress(phase: ImportPhase.extracting));
    final appDir = await getApplicationSupportDirectory();
    final tmpBase = await getTemporaryDirectory();
    final tempDir = Directory('${tmpBase.path}/sp_import_temp');
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);
    await Directory('${tempDir.path}/files').create(recursive: true);

    try {
      await _extractSec(filePath, tempDir);
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Failed to extract .sec file: $e');
    }

    final metadataFile = File('${tempDir.path}/metadata.json');
    if (!await metadataFile.exists()) {
      await tempDir.delete(recursive: true);
      throw const ImportException('Invalid .sec: metadata.json not found.');
    }

    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(await metadataFile.readAsString())
          as Map<String, dynamic>;
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Corrupt metadata.json: $e');
    }

    final version = meta['format_version'] as String? ?? '1.0';
    if (version == '2.0' || version == '2.1') {
      return _importV2(meta, tempDir, appDir.path, report);
    } else {
      return _importV1(meta, tempDir, appDir.path, report);
    }
  }

  // ── General Quiz collection (.secquiz) import ───────────────────────────
  //
  // Much simpler than a lecture import: no videos, so no per-segment outer
  // GCM device-binding loop — question images are plain AES-128-CBC (same
  // as lecture PDFs/files), decrypted only in-memory at serve time. Extracts
  // to courses/{collectionId}/ (the SAME directory convention as a lecture)
  // so the existing shelf server (server_provider.dart) and secure-storage
  // key lookup work completely unchanged for quiz question images.

  /// File-picker variant — mirrors [importSecFile]. Returns the collectionId.
  Future<String> importQuizCollectionFile({OnImportProgress? onProgress}) async {
    onProgress?.call(const ImportProgress(phase: ImportPhase.pickingFile));
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) {
      throw const ImportException('No file selected.');
    }
    return importQuizCollection(result.files.single.path!, onProgress: onProgress);
  }

  /// Import a .secquiz file from [filePath] (already on disk — skips file
  /// picker). Returns the collectionId. Mirrors [importFromPath]'s shape.
  Future<String> importQuizCollection(
    String filePath, {
    OnImportProgress? onProgress,
  }) async {
    void report(ImportProgress p) => onProgress?.call(p);

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.every((r) => r == ConnectivityResult.none)) {
      throw const ImportException(
          'No internet connection. Connect to import this quiz collection.');
    }

    report(const ImportProgress(phase: ImportPhase.extracting));
    final appDir = await getApplicationSupportDirectory();
    final tmpBase = await getTemporaryDirectory();
    final tempDir = Directory('${tmpBase.path}/sp_import_temp');
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);
    await Directory('${tempDir.path}/files').create(recursive: true);

    try {
      await _extractSec(filePath, tempDir);
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Failed to extract .secquiz file: $e');
    }

    final metadataFile = File('${tempDir.path}/metadata.json');
    if (!await metadataFile.exists()) {
      await tempDir.delete(recursive: true);
      throw const ImportException('Invalid .secquiz: metadata.json not found.');
    }

    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(await metadataFile.readAsString())
          as Map<String, dynamic>;
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Corrupt metadata.json: $e');
    }

    final collectionId = meta['collection_id'] as String? ?? '';
    final courseId = meta['course_id'] as String? ?? '';
    final createdAt = meta['created_at'] as String? ?? '';
    if (collectionId.isEmpty || courseId.isEmpty) {
      await tempDir.delete(recursive: true);
      throw const ImportException(
          'Invalid .secquiz: missing collection_id/course_id.');
    }

    if (await _quizCollectionUpToDate(appDir.path, collectionId, createdAt)) {
      await tempDir.delete(recursive: true);
      report(const ImportProgress(phase: ImportPhase.done));
      return collectionId;
    }

    final collectionDir = Directory('${appDir.path}/courses/$collectionId');
    if (await collectionDir.exists()) await collectionDir.delete(recursive: true);
    await collectionDir.parent.create(recursive: true);
    await tempDir.rename(collectionDir.path);

    report(const ImportProgress(phase: ImportPhase.fetchingKey));
    final deviceId = await DeviceIdUtil.getDeviceId();
    try {
      final data = await _callCloudFunction('getCourseKey', {
        'lectureId': collectionId,
        'courseId': courseId,
        'deviceId': deviceId,
      });
      final keyHex = data['keyHex'] as String;
      await _storage.storeKey(collectionId, keyHex);
    } on FirebaseFunctionsException catch (e) {
      await collectionDir.delete(recursive: true);
      throw KeyFetchException('Could not fetch key: ${e.code} — ${e.message}');
    } catch (e) {
      await collectionDir.delete(recursive: true);
      throw KeyFetchException('Key fetch failed: $e');
    }

    await _markQuizCollectionImported(appDir.path, collectionId, createdAt);
    report(const ImportProgress(phase: ImportPhase.done));
    return collectionId;
  }

  // ── Update (.secupdate) apply ───────────────────────────────────────────

  /// Applies a `.secupdate` delta package to an already-imported lecture.
  /// Unlike [importFromPath], this does NOT wipe the local lecture folder —
  /// it reconciles it against the package's `all_video_ids`/`all_file_ids`
  /// (the full authoritative lists): anything missing gets extracted from
  /// the package, anything no longer listed gets deleted (reclaiming
  /// space), anything already present and still listed is left untouched.
  /// The reused course key already sits in secure_storage from the original
  /// import — no Cloud Function call needed here.
  Future<void> applyUpdate(String filePath, {OnImportProgress? onProgress}) async {
    void report(ImportProgress p) => onProgress?.call(p);

    report(const ImportProgress(phase: ImportPhase.extracting));
    final appDir = await getApplicationSupportDirectory();
    final tmpBase = await getTemporaryDirectory();
    final tempDir = Directory('${tmpBase.path}/sp_update_temp');
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);

    try {
      await _extractSec(filePath, tempDir);
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Failed to extract .secupdate file: $e');
    }

    final metadataFile = File('${tempDir.path}/metadata.json');
    if (!await metadataFile.exists()) {
      await tempDir.delete(recursive: true);
      throw const ImportException('Invalid .secupdate: metadata.json not found.');
    }

    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw ImportException('Corrupt metadata.json: $e');
    }

    if (meta['package_type'] != 'update') {
      await tempDir.delete(recursive: true);
      throw const ImportException('This is not an update package.');
    }

    final lectureId = meta['lecture_id'] as String;
    final lectureDir = Directory('${appDir.path}/courses/$lectureId');
    if (!await lectureDir.exists()) {
      await tempDir.delete(recursive: true);
      throw const ImportException(
          'This lecture is not downloaded yet. Get the full lecture file first, then apply this update.');
    }

    final localMetaFile = File('${lectureDir.path}/metadata.json');
    final localMeta = jsonDecode(await localMetaFile.readAsString()) as Map<String, dynamic>;
    final localVideos = ((localMeta['videos'] as List?) ?? []).cast<Map<String, dynamic>>();
    final localFiles = ((localMeta['files'] as List?) ?? []).cast<Map<String, dynamic>>();
    final localFileIvMap = Map<String, String>.from(localMeta['file_iv_map'] as Map? ?? {});
    final localVideoIds = localVideos.map((v) => v['id'] as String).toSet();
    final localFileIds = localFiles.map((f) => f['id'] as String).toSet();

    final allVideoIds = List<String>.from(meta['all_video_ids'] as List? ?? []);
    final allFileIds = List<String>.from(meta['all_file_ids'] as List? ?? []);
    final newVideoMetas = ((meta['videos'] as List?) ?? []).cast<Map<String, dynamic>>();
    final newFileMetas = ((meta['files'] as List?) ?? []).cast<Map<String, dynamic>>();
    final newFileIvMap = Map<String, String>.from(meta['file_iv_map'] as Map? ?? {});
    final newVideoIdsInPkg = newVideoMetas.map((v) => v['id'] as String).toSet();
    final newFileIdsInPkg = newFileMetas.map((f) => f['id'] as String).toSet();

    // Every id the package claims should exist afterward must be either
    // already local or included in this package — otherwise this device
    // skipped too much and needs a more complete update or the full lecture.
    for (final vid in allVideoIds) {
      if (!localVideoIds.contains(vid) && !newVideoIdsInPkg.contains(vid)) {
        await tempDir.delete(recursive: true);
        throw const ImportException(
            'This update needs video content this device is missing. Get a more recent update or the full lecture file.');
      }
    }
    for (final fid in allFileIds) {
      if (!localFileIds.contains(fid) && !newFileIdsInPkg.contains(fid)) {
        await tempDir.delete(recursive: true);
        throw const ImportException(
            'This update needs a file this device is missing. Get a more recent update or the full lecture file.');
      }
    }

    report(const ImportProgress(phase: ImportPhase.fetchingKey));
    final keyHex = await _storage.getKey(lectureId);
    if (keyHex == null) {
      await tempDir.delete(recursive: true);
      throw const ImportException('No stored key for this lecture — re-import the full lecture file.');
    }
    final deviceId = await DeviceIdUtil.getDeviceId();

    // Quizzes always ship in full — read now, while tempDir still exists.
    final tempQuizzesFile = File('${tempDir.path}/quizzes.json');
    final quizzesJson =
        await tempQuizzesFile.exists() ? await tempQuizzesFile.readAsString() : null;

    try {
      // Move new video folders into place, then device-bind (outer GCM) them —
      // same step manual full import does, just for a smaller set of videos.
      final totalSegments = await _countSegmentsV2(tempDir, newVideoIdsInPkg);
      int securedSoFar = 0;
      var videoIndex = 0;
      for (final vid in newVideoIdsInPkg) {
        final src = Directory('${tempDir.path}/videos/$vid');
        if (!await src.exists()) continue;
        videoIndex++;
        final destDir = Directory('${lectureDir.path}/videos/$vid');
        if (await destDir.exists()) await destDir.delete(recursive: true);
        await destDir.parent.create(recursive: true);
        await src.rename(destDir.path);
        securedSoFar = await _outerEncryptSegmentsV2(
          lectureDir: lectureDir,
          videoId: vid,
          keyHex: keyHex,
          deviceId: deviceId,
          securedSoFar: securedSoFar,
          totalSegments: totalSegments,
          videoIndex: videoIndex,
          totalVideos: newVideoIdsInPkg.length,
          report: report,
        );
      }

      // Files (regular + quiz images) are single-layer AES-128-CBC, decrypted
      // in-memory by the shelf server on request — no device-binding step
      // needed at import time, just move the already-encrypted bytes.
      final tempFilesDir = Directory('${tempDir.path}/files');
      if (await tempFilesDir.exists()) {
        final destFilesDir = Directory('${lectureDir.path}/files');
        await destFilesDir.create(recursive: true);
        for (final entry in tempFilesDir.listSync().whereType<File>()) {
          final destFile = File('${destFilesDir.path}/${entry.uri.pathSegments.last}');
          await entry.rename(destFile.path);
        }
      }

      // Delete removed video/file folders — this is what reclaims space for
      // content the teacher dropped, without touching anything still listed.
      for (final vid in localVideoIds.difference(allVideoIds.toSet())) {
        final dir = Directory('${lectureDir.path}/videos/$vid');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      for (final fid in localFileIds.difference(allFileIds.toSet())) {
        final file = File('${lectureDir.path}/files/$fid');
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      throw ImportException('Failed to apply update: $e');
    } finally {
      await tempDir.delete(recursive: true);
    }

    // Merge metadata.json: keep local entries for ids still listed, add
    // fresh entries for newly-bundled ids, drop everything else.
    final videosById = <String, Map<String, dynamic>>{
      for (final v in localVideos) v['id'] as String: v,
      for (final v in newVideoMetas) v['id'] as String: v,
    };
    final filesById = <String, Map<String, dynamic>>{
      for (final f in localFiles) f['id'] as String: f,
      for (final f in newFileMetas) f['id'] as String: f,
    };
    final mergedVideos = allVideoIds.map((id) => videosById[id]).whereType<Map<String, dynamic>>().toList();
    final mergedFiles = allFileIds.map((id) => filesById[id]).whereType<Map<String, dynamic>>().toList();

    // Quiz-image IVs always ride along with newFileIvMap (quizzes.json is
    // always shipped in full) even though they're not in all_file_ids —
    // keep any key that's either a still-listed file or present in this
    // update's fresh file_iv_map (covers every quiz image every time).
    final mergedFileIvMap = <String, String>{};
    for (final key in {...localFileIvMap.keys, ...newFileIvMap.keys}) {
      if (allFileIds.contains(key) || newFileIvMap.containsKey(key)) {
        mergedFileIvMap[key] = newFileIvMap[key] ?? localFileIvMap[key]!;
      }
    }

    final totalDuration = mergedVideos.fold<int>(
        0, (acc, v) => acc + ((v['duration_seconds'] as num?)?.toInt() ?? 0));

    final mergedMeta = Map<String, dynamic>.from(localMeta)
      ..['videos'] = mergedVideos
      ..['files'] = mergedFiles
      ..['file_iv_map'] = mergedFileIvMap
      ..['total_duration_seconds'] = totalDuration;
    await localMetaFile.writeAsString(jsonEncode(mergedMeta));

    if (quizzesJson != null) {
      await File('${lectureDir.path}/quizzes.json').writeAsString(quizzesJson);
    }

    report(const ImportProgress(phase: ImportPhase.done));
  }

  // Extracts a .sec (ZIP) file to destDir.
  // On Windows, falls back to PowerShell Expand-Archive if the native
  // flutter_archive plugin is unavailable (MissingPluginException).
  static Future<void> _extractSec(String secPath, Directory destDir) async {
    if (Platform.isWindows) {
      try {
        await ZipFile.extractToDirectory(
          zipFile: File(secPath),
          destinationDir: destDir,
        );
      } on MissingPluginException {
        // Expand-Archive rejects non-.zip extensions — copy to a temp .zip first
        final tempZip = File('$secPath.zip');
        await File(secPath).copy(tempZip.path);
        try {
          final result = await Process.run('powershell', [
            '-command',
            'Expand-Archive -Path "${tempZip.path.replaceAll('"', '`"')}" '
                '-DestinationPath "${destDir.path.replaceAll('"', '`"')}" -Force',
          ]);
          if (result.exitCode != 0) {
            throw Exception('PowerShell extraction failed: ${result.stderr}');
          }
        } finally {
          if (await tempZip.exists()) await tempZip.delete();
        }
      }
    } else {
      await ZipFile.extractToDirectory(
        zipFile: File(secPath),
        destinationDir: destDir,
      );
    }
  }
}
