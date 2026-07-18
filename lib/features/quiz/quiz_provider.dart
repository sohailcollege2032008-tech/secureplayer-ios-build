import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/quiz.dart';
import '../../core/services/quiz_db_service.dart';

// ── Quiz loading ──────────────────────────────────────────────────────────────

final courseQuizzesProvider =
    FutureProvider.family<List<Quiz>, String>((ref, courseId) async {
  final appDir = await getApplicationSupportDirectory();
  final file = File('${appDir.path}/courses/$courseId/quizzes.json');
  if (!await file.exists()) return [];

  try {
    final list = jsonDecode(await file.readAsString()) as List;
    return list.map((e) => Quiz.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
});

/// Loads quizzes for a standalone General Quiz collection (imported from a
/// `.secquiz` file) — reads the exact same quizzes.json shape as a lecture,
/// just from `courses/{collectionId}/` instead of `courses/{lectureId}/`
/// (SecImporter.importQuizCollection extracts there so the existing shelf
/// server / secure-storage key lookup work unchanged for quiz images).
/// isGeneralQuiz is stamped true here since quizzes.json itself never
/// carries that flag — see Quiz.isGeneralQuiz's doc comment.
final generalQuizzesProvider =
    FutureProvider.family<List<Quiz>, String>((ref, collectionId) async {
  final appDir = await getApplicationSupportDirectory();
  final file = File('${appDir.path}/courses/$collectionId/quizzes.json');
  if (!await file.exists()) return [];

  try {
    final list = jsonDecode(await file.readAsString()) as List;
    return list
        .map((e) =>
            Quiz.fromJson(e as Map<String, dynamic>).copyWith(isGeneralQuiz: true))
        .toList();
  } catch (_) {
    return [];
  }
});

final courseExamProvider =
    FutureProvider.family<Quiz?, String>((ref, courseId) async {
  final appDir = await getApplicationSupportDirectory();
  final file = File('${appDir.path}/courses/$courseId/course_exam.json');
  if (!await file.exists()) return null;

  try {
    final list = jsonDecode(await file.readAsString()) as List;
    if (list.isEmpty) return null;
    return Quiz.fromJson(list.first as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
});

final videoQuizProvider =
    FutureProvider.family<Quiz?, String>((ref, compoundId) async {
  final appDir = await getApplicationSupportDirectory();
  final file = File('${appDir.path}/courses/$compoundId/quizzes.json');
  if (!await file.exists()) return null;

  try {
    final list = jsonDecode(await file.readAsString()) as List;
    if (list.isEmpty) return null;
    return Quiz.fromJson(list.first as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
});

// ── Quiz stats ────────────────────────────────────────────────────────────────

final quizStatsProvider =
    FutureProvider.family<QuizStats, String>((ref, courseId) async {
  return QuizDbService.instance.statsForCourse(courseId);
});

// ── Starred questions ─────────────────────────────────────────────────────────

class StarredState {
  const StarredState(this.starred);
  final Set<String> starred; // question_ids

  bool isStarred(String questionId) => starred.contains(questionId);
}

class StarredNotifier extends StateNotifier<StarredState> {
  StarredNotifier(this._courseId) : super(const StarredState({})) {
    _load();
  }

  final String _courseId;

  Future<void> _load() async {
    final ids = await QuizDbService.instance.starredQuestionIds(_courseId);
    state = StarredState(ids);
  }

  Future<void> toggle({
    required String questionId,
    required String quizId,
    required String lectureId,
  }) async {
    if (state.isStarred(questionId)) {
      await QuizDbService.instance.unstarQuestion(questionId, quizId);
      state = StarredState({...state.starred}..remove(questionId));
    } else {
      await QuizDbService.instance.starQuestion(
        questionId: questionId,
        quizId: quizId,
        lectureId: lectureId,
        courseId: _courseId,
      );
      state = StarredState({...state.starred, questionId});
    }
  }
}

final starredProvider =
    StateNotifierProvider.family<StarredNotifier, StarredState, String>(
  (ref, courseId) => StarredNotifier(courseId),
);

// ── Quiz result tracking ──────────────────────────────────────────────────────

/// Tracks which quizzes the student has already answered (in-memory per session).
/// Persistence is handled by QuizDbService (SQLite).
class QuizResultNotifier extends StateNotifier<Map<String, QuizResult>> {
  QuizResultNotifier(this._courseId) : super({});

  final String _courseId;

  /// Records the result for [quiz]. [selectedIndex] applies to the first
  /// (or only) question in popup quizzes. For multi-question quizzes, pass
  /// the per-question selectedIndex via [questionAnswers].
  Future<void> saveResult(
    String quizId,
    int selectedIndex,
    Quiz quiz, {
    String lectureId = '',
    Map<String, int>? questionAnswers,
  }) async {
    // Only track first attempt per quiz in session state (UI guard)
    if (state.containsKey(quizId)) return;

    final question = quiz.questions.isNotEmpty ? quiz.questions.first : null;
    if (question == null) return;

    final effectiveLectureId = lectureId.isNotEmpty
        ? lectureId
        : quiz.courseId; // fallback — won't break SRS queries

    if (questionAnswers != null) {
      // Multi-question quiz — record each answer individually
      for (final q in quiz.questions) {
        final ans = questionAnswers[q.id];
        if (ans == null) continue;
        await QuizDbService.instance.recordAttempt(
          question: q,
          quizId: quizId,
          lectureId: effectiveLectureId,
          courseId: _courseId,
          selectedIndex: ans,
        );
      }
    } else {
      // Popup quiz — single first question
      await QuizDbService.instance.recordAttempt(
        question: question,
        quizId: quizId,
        lectureId: effectiveLectureId,
        courseId: _courseId,
        selectedIndex: selectedIndex,
      );
    }

    final result = QuizResult(
      quizId: quizId,
      selectedIndex: selectedIndex,
      isCorrect: selectedIndex == question.correctIndex,
      answeredAt: DateTime.now(),
    );
    state = {...state, quizId: result};
  }

  bool hasAnswered(String quizId) => state.containsKey(quizId);
}

final quizResultProvider = StateNotifierProvider.family<QuizResultNotifier,
    Map<String, QuizResult>, String>((ref, courseId) {
  return QuizResultNotifier(courseId);
});
