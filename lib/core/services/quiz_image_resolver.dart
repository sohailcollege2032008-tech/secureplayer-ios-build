import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/quiz.dart';

/// Resolves quiz-question image bytes for export (Anki/PDF), shared by both
/// exporters so the image-sourcing logic isn't duplicated.
///
/// Course quizzes fetch encrypted bytes in-memory from the lecture's running
/// shelf server — same convention as [EncryptedImageCacheMixin]
/// (`GET /file/:lectureId/:imageId/img` with a bearer token). This requires
/// the shelf server to already be running for that lecture (e.g. because the
/// student is exporting from within an active quiz/review session); if no
/// server is running, images are silently skipped and the export proceeds
/// text-only rather than failing outright.
///
/// Personal quizzes have no DRM at all — their images are plain local files
/// under `personal_quizzes/{quizId}/images/`, read directly with no shelf
/// server or encryption involved.
class QuizImageResolver {
  const QuizImageResolver._();

  /// Returns a map of questionId -> image bytes for every question in
  /// [quiz] that has an image and could be resolved. Missing/failed images
  /// are omitted rather than throwing, so export can still proceed.
  static Future<Map<String, Uint8List>> resolveQuestionImages(
    Quiz quiz, {
    required String lectureId,
    int? shelfPort,
    String? shelfToken,
  }) async {
    final result = <String, Uint8List>{};
    for (final question in quiz.questions) {
      if (!question.hasImage) continue;
      final bytes = await resolveOneImage(
        isPersonalQuiz: quiz.isPersonalQuiz,
        quizId: quiz.id,
        lectureId: lectureId,
        imageId: question.imageId,
        shelfPort: shelfPort,
        shelfToken: shelfToken,
      );
      if (bytes != null) result[question.id] = bytes;
    }
    return result;
  }

  /// Single-image variant shared by [resolveQuestionImages] and aggregate
  /// (cross-lecture) exports that only have loose `ReviewQuestion`s rather
  /// than a whole [Quiz] object. Never throws — returns null on any failure.
  static Future<Uint8List?> resolveOneImage({
    required bool isPersonalQuiz,
    required String quizId,
    required String lectureId,
    required String imageId,
    int? shelfPort,
    String? shelfToken,
  }) async {
    try {
      return isPersonalQuiz
          ? await _readPersonalQuizImage(quizId, imageId)
          : await _fetchCourseQuizImage(
              lectureId, imageId, shelfPort, shelfToken);
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _readPersonalQuizImage(
    String quizId,
    String imageId,
  ) async {
    final appDir = await getApplicationSupportDirectory();
    final file =
        File('${appDir.path}/personal_quizzes/$quizId/images/$imageId');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  static Future<Uint8List?> _fetchCourseQuizImage(
    String lectureId,
    String imageId,
    int? port,
    String? token,
  ) async {
    if (port == null || token == null) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/file/$lectureId/$imageId/img'));
      request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.toBytes();
    } finally {
      client.close();
    }
  }
}
