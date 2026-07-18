import 'dart:io';

import '../../core/models/quiz.dart';
import '../../core/services/anki/anki_package_builder.dart';
import '../../core/services/quiz_image_resolver.dart';

/// Thrown when a course quiz's teacher hasn't enabled export for it.
/// Personal quizzes never throw this — the student owns that content.
class ExportNotAllowedException implements Exception {
  const ExportNotAllowedException();

  @override
  String toString() =>
      'Export is not allowed for this quiz — ask your teacher to enable it.';
}

/// Exports [quiz] to a single-deck Anki `.apkg` file under [outputDir].
///
/// [lectureId] is required to resolve course-quiz images through the
/// running shelf server (see [QuizImageResolver]) — pass [shelfPort]/
/// [shelfToken] when a server is already active for that lecture (e.g. the
/// export is triggered from within an active quiz/review session); if
/// omitted, images are silently skipped and the deck exports text-only.
Future<File> exportQuizToAnki(
  Quiz quiz, {
  required String lectureId,
  required Directory outputDir,
  int? shelfPort,
  String? shelfToken,
}) async {
  if (!quiz.isPersonalQuiz && !quiz.exportAllowed) {
    throw const ExportNotAllowedException();
  }

  final images = await QuizImageResolver.resolveQuestionImages(
    quiz,
    lectureId: lectureId,
    shelfPort: shelfPort,
    shelfToken: shelfToken,
  );

  final deckName = quiz.title.isNotEmpty ? quiz.title : 'SecurePlayer Quiz';
  final builder = AnkiPackageBuilder(deckName: deckName);
  for (final question in quiz.questions) {
    builder.addQuestion(
      questionId: question.id,
      quizId: quiz.id,
      questionText: question.text,
      options: question.options,
      correctIndex: question.correctIndex,
      explanation: question.explanation,
      questionDirection:
          question.questionDirectionOverride ?? quiz.questionDirection,
      explanationDirection:
          question.explanationDirectionOverride ?? quiz.explanationDirection,
      imageBytes: images[question.id],
      source: quiz.title,
    );
  }

  final bytes = await builder.build();

  if (!await outputDir.exists()) {
    await outputDir.create(recursive: true);
  }
  final safeName = _sanitizeFileName(deckName);
  final file = File('${outputDir.path}/$safeName.apkg');
  await file.writeAsBytes(bytes);
  return file;
}

String _sanitizeFileName(String input) =>
    input.replaceAll(RegExp('[\\\\/:*?"<>|]'), '_').trim();
