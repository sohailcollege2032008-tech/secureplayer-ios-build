import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../../local_server/decryption/aes_decryptor.dart';
import '../../security_layer/secure_storage/secure_storage_service.dart';

/// Resolves and decrypts a FairPlay package's parallel-audio file
/// (fairplay_lectures/{lectureId}/videos/{videoId}/audio.m4a) into a
/// plaintext temp file the audio player can open.
///
/// The audio file is encrypted exactly like .sec lecture files (AES-128-CBC
/// with the lecture's course key — the same aes_key_hex getCourseKey
/// returns — per-file random IV in metadata.json's file_iv_map under
/// "audio:<videoId>"). No DRM involvement: the key is fetched once at import
/// (getCourseKey) and lives in secure storage, and the decrypt happens
/// locally with the same AesDecryptor the .sec path uses.
///
/// The FairPlay VIDEO key (skd://, per-video, KSM-issued) is a completely
/// separate key and untouched by this — the video is step2-style FairPlay
/// with no audio track at all, so AVPlayer never sees the audio key.
class ParallelAudioLoader {
  ParallelAudioLoader({
    this.storage,
    this.applicationDocumentsDir,
    this.readMetadata,
  });

  final SecureStorageService? storage;
  final Future<Directory> Function()? applicationDocumentsDir;
  final Future<Map<String, dynamic>> Function(String lectureId)? readMetadata;

  late final SecureStorageService _storage = storage ?? SecureStorageService();

  Future<Directory> _docsDir() async {
    final custom = applicationDocumentsDir?.call();
    return custom ?? getApplicationDocumentsDirectory();
  }

  Future<Map<String, dynamic>> _loadMetadata(String lectureId) {
    if (readMetadata != null) return readMetadata!(lectureId);
    return _metadataFromDisk(lectureId);
  }

  Future<Map<String, dynamic>> _metadataFromDisk(String lectureId) async {
    final dir = await _docsDir();
    final file = File('${dir.path}/fairplay_lectures/$lectureId/metadata.json');
    if (!await file.exists()) {
      throw StateError('metadata.json missing for lecture $lectureId');
    }
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  /// Returns the decrypted temp file path for this lecture's video, or null
  /// when the video has no parallel-audio file. The temp file path is
  /// deterministic (same lecture+video -> same path), so re-entry reuses it.
  Future<String?> prepare(String lectureId, String videoId) async {
    final meta = await _loadMetadata(lectureId);

    String? audioFilename;
    final videos = meta['videos'] as List? ?? [];
    for (final v in videos) {
      final vMap = v as Map<String, dynamic>;
      if (vMap['id'] == videoId) {
        audioFilename = vMap['separate_audio'] as String?;
        break;
      }
    }
    if (audioFilename == null || audioFilename.isEmpty) return null;

    final ivMap = meta['file_iv_map'] as Map<String, dynamic>? ?? {};
    final ivHex = ivMap['audio:$videoId'] as String?;
    if (ivHex == null || ivHex.length != 32) {
      throw StateError(
        'Parallel audio for $lectureId/$videoId has no IV in file_iv_map',
      );
    }

    final keyHex = await _storage.getKey(lectureId);
    if (keyHex == null) {
      throw StateError(
        'No decryption key for lecture $lectureId (re-import the file)',
      );
    }

    final dir = await _docsDir();
    final encryptedPath =
        '${dir.path}/fairplay_lectures/$lectureId/videos/$videoId/$audioFilename';
    final encrypted = File(encryptedPath);
    if (!await encrypted.exists()) {
      throw StateError('Parallel audio missing on disk: $encryptedPath');
    }

    final cacheDir = Directory('${dir.path}/audio_cache');
    await cacheDir.create(recursive: true);
    final tempPath = '${cacheDir.path}/${lectureId}__$videoId.m4a';

    final ciphertext = await encrypted.readAsBytes();
    final key = AesDecryptor.hexToBytes(keyHex);
    final iv = AesDecryptor.hexToBytes(ivHex);
    final plaintext = await Isolate.run(() => AesDecryptor.decrypt(
          encryptedBytes: ciphertext,
          key: key,
          iv: iv,
          segmentName: 'parallel-audio',
        ));
    await File(tempPath).writeAsBytes(plaintext, flush: true);
    return tempPath;
  }

  /// Removes the cached plaintext (called on player teardown). Fails soft.
  Future<void> clearCache(String lectureId, String videoId) async {
    try {
      final dir = await _docsDir();
      final f = File('${dir.path}/audio_cache/${lectureId}__$videoId.m4a');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
