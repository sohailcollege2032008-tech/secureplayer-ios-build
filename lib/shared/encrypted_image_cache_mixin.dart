import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Fetches and caches quiz-question images, for both course quizzes
/// (encrypted, bundled in the .sec under files/{imageId}, decrypted
/// in-memory by the shelf server at GET /file/{lectureId}/{imageId}/img —
/// never written to disk) and personal quizzes (plain local files under
/// personal_quizzes/{quizId}/images/{imageId} — no DRM, no shelf server).
/// Both share one cache keyed `'$scopeId/$imageId'` (scopeId is a lectureId
/// for course quizzes, a quizId for personal ones), so [cachedImage] doesn't
/// need to know which kind of quiz it's reading for.
///
/// Mix into any State that needs to show quiz-question images (quiz taking,
/// SRS review) so the fetch/cache logic isn't duplicated per screen.
mixin EncryptedImageCacheMixin<T extends StatefulWidget> on State<T> {
  final Map<String, Uint8List> _imageCache = {};
  final Set<String> _imageLoading = {};

  Uint8List? cachedImage(String scopeId, String imageId) =>
      _imageCache['$scopeId/$imageId'];

  Future<void> loadImageIfNeeded(
      String lectureId, String imageId, int port, String token) async {
    final key = '$lectureId/$imageId';
    if (_imageCache.containsKey(key) || _imageLoading.contains(key)) return;
    _imageLoading.add(key);
    try {
      final client = HttpClient();
      final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/file/$lectureId/$imageId/img'));
      request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != 200) return;
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      if (mounted) setState(() => _imageCache[key] = builder.toBytes());
    } catch (_) {
      // Text/options still work without the image.
    } finally {
      _imageLoading.remove(key);
    }
  }

  /// Personal-quiz counterpart of [loadImageIfNeeded] — reads the plain
  /// local file directly, no shelf server or encryption involved.
  Future<void> loadPersonalImageIfNeeded(String quizId, String imageId) async {
    final key = '$quizId/$imageId';
    if (_imageCache.containsKey(key) || _imageLoading.contains(key)) return;
    _imageLoading.add(key);
    try {
      final appDir = await getApplicationSupportDirectory();
      final file =
          File('${appDir.path}/personal_quizzes/$quizId/images/$imageId');
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => _imageCache[key] = bytes);
    } catch (_) {
      // Text/options still work without the image.
    } finally {
      _imageLoading.remove(key);
    }
  }
}
