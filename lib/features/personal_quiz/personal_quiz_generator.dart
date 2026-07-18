import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/models/quiz.dart';
import 'personal_quiz_draft_state.dart';

/// Extracts a file extension including the leading dot (e.g. '.jpg'), or
/// '' if none — avoids adding the `path` package (already only a transitive
/// dependency here) for this one trivial string operation.
String _fileExtension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot);
}

/// Converts an in-progress [PersonalQuizDraft] into a runtime [Quiz] and
/// persists it to `personal_quizzes/{quizId}/quiz.json` — the same
/// array-of-quiz-JSON shape as a course lecture's `quizzes.json`, so
/// `personalQuizzesProvider` can reuse `Quiz.fromJson` verbatim (mirrors
/// generalQuizzesProvider's identical convention for General Quiz
/// collections).
///
/// Always sets `exportAllowed: true` and `isPersonalQuiz: true` — the
/// student owns this content, so the teacher-permission gate never applies.
/// Scope is always lecture-level equivalent (empty videoIds) since personal
/// quizzes are only ever opened deliberately from the Personal Quizzes list,
/// never auto-triggered during video playback.
///
/// Images: the whole `personal_quizzes/{quizId}/images/` directory is wiped
/// and rewritten from the draft's current questions on every generate, so
/// repeated edits never accumulate orphaned images from a removed/replaced
/// picture.
Future<Quiz> generatePersonalQuiz(PersonalQuizDraft draft) async {
  final appDir = await getApplicationSupportDirectory();
  final quizDir = Directory('${appDir.path}/personal_quizzes/${draft.id}');
  final imagesDir = Directory('${quizDir.path}/images');

  if (await imagesDir.exists()) {
    await imagesDir.delete(recursive: true);
  }
  await imagesDir.create(recursive: true);

  final questions = <QuizQuestion>[];
  for (final q in draft.questions) {
    var storedImageId = '';
    if (q.imagePath.isNotEmpty && q.imageId.isNotEmpty) {
      final sourceFile = File(q.imagePath);
      if (await sourceFile.exists()) {
        final ext = _fileExtension(q.imagePath);
        storedImageId = '${q.imageId}$ext';
        await sourceFile.copy('${imagesDir.path}/$storedImageId');
      }
    }

    questions.add(QuizQuestion(
      id: q.id,
      text: q.text,
      options: q.options,
      correctIndex: q.correctIndex,
      explanation: q.explanation,
      imageId: storedImageId,
      questionDirectionOverride: q.questionDirectionOverride,
      explanationDirectionOverride: q.explanationDirectionOverride,
    ));
  }

  final quiz = Quiz(
    id: draft.id,
    courseId: '',
    videoIds: const [],
    title: draft.title.trim().isEmpty ? 'Personal Quiz' : draft.title.trim(),
    questions: questions,
    questionDirection: draft.questionDirection,
    explanationDirection: draft.explanationDirection,
    exportAllowed: true,
    isPersonalQuiz: true,
  );

  final quizFile = File('${quizDir.path}/quiz.json');
  await quizFile.writeAsString(jsonEncode([quiz.toJson()]));

  return quiz;
}

/// Reverse-maps a stored personal [Quiz] back into an editable draft — used
/// by the "Edit" action on the Personal Quizzes list. Picked-image state
/// (`imagePath`) is intentionally left empty: the stored image already lives
/// under `personal_quizzes/{quizId}/images/`, so there's nothing to
/// re-attach unless the student explicitly changes it. `imageId` is kept as-
/// is so an unrelated edit doesn't orphan the existing image (the generator
/// only overwrites an image file when a new `imagePath` is actually set).
PersonalQuizDraft draftFromPersonalQuiz(Quiz quiz) => PersonalQuizDraft(
      id: quiz.id,
      title: quiz.title,
      questionDirection: quiz.questionDirection,
      explanationDirection: quiz.explanationDirection,
      questions: quiz.questions
          .map((q) => PersonalQuizQuestionDraft(
                id: q.id,
                text: q.text,
                options: q.options,
                correctIndex: q.correctIndex,
                explanation: q.explanation,
                imageId: q.imageId,
                questionDirectionOverride: q.questionDirectionOverride,
                explanationDirectionOverride: q.explanationDirectionOverride,
              ))
          .toList(),
    );
