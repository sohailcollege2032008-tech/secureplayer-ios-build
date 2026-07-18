import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/quiz.dart';

/// Lists every generated personal quiz — direct mirror of
/// `generalQuizzesProvider` (lib/features/quiz/quiz_provider.dart): reads
/// the identical array-of-quiz-JSON shape, just from
/// `personal_quizzes/{quizId}/quiz.json` instead of
/// `courses/{collectionId}/quizzes.json`, and stamps `isPersonalQuiz: true`
/// (a runtime-only flag never present in the JSON itself, same convention
/// as `isGeneralQuiz`).
final personalQuizzesProvider =
    FutureProvider.autoDispose<List<Quiz>>((ref) async {
  final appDir = await getApplicationSupportDirectory();
  final root = Directory('${appDir.path}/personal_quizzes');
  if (!await root.exists()) return [];

  final quizzes = <Quiz>[];
  await for (final entry in root.list()) {
    if (entry is! Directory) continue;
    final quizFile = File('${entry.path}/quiz.json');
    if (!await quizFile.exists()) continue;
    try {
      final list = jsonDecode(await quizFile.readAsString()) as List;
      quizzes.addAll(list
          .map((e) => Quiz.fromJson(e as Map<String, dynamic>)
              .copyWith(isPersonalQuiz: true)));
    } catch (_) {
      // Skip a corrupted draft rather than failing the whole list.
    }
  }
  return quizzes;
});

/// Deletes a personal quiz's whole directory (quiz.json + images).
Future<void> deletePersonalQuiz(String quizId) async {
  final appDir = await getApplicationSupportDirectory();
  final dir = Directory('${appDir.path}/personal_quizzes/$quizId');
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}
