import '../../core/models/review_settings.dart';
import '../../core/services/quiz_db_service.dart';
import '../../core/services/srs_scheduler.dart';
import '../review/review_deck.dart';
import 'quiz_attempt_result.dart';

/// The single place a quiz attempt's results are allowed to affect the
/// review/SRS system. Called two ways:
///  - automatically, silently, only on a quiz's first-ever attempt
///    (quiz_result_screen.dart, gated on QuizHistoryService.isFirstAttempt)
///  - on explicit "yes, update" confirmation for any later retake, with a
///    student-chosen [scope] deciding which of this quiz's questions stay in
///    (or newly enter) the review pool
///
/// Either way this is always a full reset for the quiz's question set: every
/// existing question_srs row for [result.quiz.id] is deleted first, then a
/// fresh row (as if seen for the first time — reps 0, no prior interval) is
/// inserted for whichever questions pass [scope]. There is no partial/
/// incremental update path — an "update" always behaves exactly like a first
/// solve, even if the quiz's questions weren't due yet, per the explicit
/// product decision this was built against.
Future<void> syncAttemptToReview(
  QuizAttemptResult result, {
  required ReviewFilterMode scope,
  required ReviewSettings settings,
}) async {
  final quiz = result.quiz;
  await QuizDbService.instance.deleteSrsForQuiz(quiz.id);

  for (var i = 0; i < quiz.questions.length; i++) {
    final question = quiz.questions[i];
    final selected = i < result.selectedIndices.length
        ? result.selectedIndices[i]
        : -1;
    if (selected < 0) continue;

    final isCorrect = selected == question.correctIndex;
    final isStarred =
        await QuizDbService.instance.isStarred(question.id, quiz.id);

    final included = switch (scope) {
      ReviewFilterMode.wholeExam => true,
      ReviewFilterMode.wrongOnly => !isCorrect,
      ReviewFilterMode.starredOnly => isStarred,
      ReviewFilterMode.starredOrWrong => isStarred || !isCorrect,
    };
    if (!included) continue;

    // "Important or wrong" both mean "treat as if already gotten wrong once" —
    // a starred question is seeded exactly like a wrong one regardless of
    // whether this attempt actually answered it correctly.
    final rating =
        (!isCorrect || isStarred) ? ReviewRating.again : ReviewRating.medium;
    final now = DateTime.now();
    final next = SrsScheduler.next(
      reps: 0,
      intervalMin: 0,
      rating: rating,
      now: now,
      settings: settings,
    );
    await QuizDbService.instance.upsertSrsState(
      questionId: question.id,
      quizId: quiz.id,
      lectureId: result.lectureId,
      courseId: quiz.courseId,
      next: next,
      rating: rating,
      reviewedAt: now,
    );
  }
}
