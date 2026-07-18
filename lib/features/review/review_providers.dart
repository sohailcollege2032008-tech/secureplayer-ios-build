import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/quiz.dart';
import '../../core/services/quiz_db_service.dart';
import '../courses/courses_provider.dart';
import '../courses/enrolled_courses_provider.dart';
import '../personal_quiz/personal_quiz_provider.dart';
import '../quiz/quiz_provider.dart';
import 'review_deck.dart';

/// Synthetic parentCourseId grouping every personal quiz into its own
/// section in the scope pickers, appended last so course content stays
/// visually primary. Personal quizzes use `'personal:{quizId}'` as their
/// "lectureId" throughout review/SRS/starring — the same
/// treat-this-id-like-a-lectureId convention already used for General Quiz
/// collections (see courseQuizzesProvider vs generalQuizzesProvider).
const String kPersonalQuizGroupId = '__personal__';
const String kPersonalQuizGroupTitle = 'Personal Quizzes';
const String _kPersonalQuizIdPrefix = 'personal:';

String personalQuizLectureId(String quizId) => '$_kPersonalQuizIdPrefix$quizId';

/// Keeps an autoDispose provider's cached value alive for [ttl] after its
/// last listener is removed, instead of disposing instantly — revisiting the
/// screen within [ttl] costs zero additional reads. A stale cache self-heals
/// after [ttl] with no manual refresh path needed.
void _keepAliveFor(Ref ref, Duration ttl) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onDispose(() => timer?.cancel());
  ref.onCancel(() => timer = Timer(ttl, link.close));
  ref.onResume(() => timer?.cancel());
}

const _kReviewOverviewTtl = Duration(minutes: 5);

/// Resolves the quizzes for one scope-picker entry — a real lectureId
/// (`courseQuizzesProvider`), or a personal-quiz synthetic id produced by
/// [personalQuizLectureId], which fetches just that one quiz from
/// [personalQuizzesProvider]. Shared by review_session_screen.dart and
/// starred_browse_screen.dart's deck-building code so both understand
/// personal-quiz ids coming out of the scope pickers, not just real
/// lectures/General Quiz collections.
Future<List<Quiz>> quizzesForScopeId(WidgetRef ref, String scopeId) async {
  if (scopeId.startsWith(_kPersonalQuizIdPrefix)) {
    final quizId = scopeId.substring(_kPersonalQuizIdPrefix.length);
    final personalQuizzes = await ref.watch(personalQuizzesProvider.future);
    for (final q in personalQuizzes) {
      if (q.id == quizId) return [q];
    }
    return const [];
  }
  return ref.watch(courseQuizzesProvider(scopeId).future);
}

/// Per-lecture summary shown in the review scope picker.
class ReviewLectureInfo {
  const ReviewLectureInfo({
    required this.lectureId,
    required this.lectureTitle,
    required this.parentCourseId,
    required this.totalQuestions,
    required this.dueCount,
    this.nextDueAt,
    this.isPersonalQuiz = false,
  });

  final String lectureId;
  final String lectureTitle;
  final String parentCourseId;

  /// Non-popup questions in this lecture's quizzes.json.
  final int totalQuestions;

  /// Due tracked questions + never-seen questions.
  final int dueCount;

  final DateTime? nextDueAt;

  /// True for entries sourced from a student-authored personal quiz rather
  /// than course content — drives the "Personal" badge in the scope picker.
  final bool isPersonalQuiz;
}

/// Lectures grouped under their parent course for the scope picker.
class ReviewCourseGroup {
  const ReviewCourseGroup({
    required this.parentCourseId,
    required this.title,
    required this.lectures,
  });

  final String parentCourseId;
  final String title;
  final List<ReviewLectureInfo> lectures;

  int get dueCount => lectures.fold(0, (sum, l) => sum + l.dueCount);
  int get totalQuestions =>
      lectures.fold(0, (sum, l) => sum + l.totalQuestions);
}

/// Overview of every locally imported lecture with quiz/due counts, grouped
/// by parent course. Cheap: local quizzes.json reads + ONE SQLite query.
/// Course titles come from the Firestore-backed [enrolledCoursesProvider]
/// but only via valueOrNull — fully usable offline with fallback labels.
final reviewScopeOverviewProvider =
    FutureProvider.autoDispose<List<ReviewCourseGroup>>((ref) async {
  _keepAliveFor(ref, _kReviewOverviewTtl);
  final courses = await ref.watch(localCoursesProvider.future);
  final enrolledCourses = await ref.watch(enrolledCoursesProvider.future);

  // localCoursesProvider emits one entry per VIDEO — dedupe into lectures.
  final lectureTitles = <String, String>{};
  final lectureParents = <String, String>{};
  for (final c in courses) {
    lectureTitles.putIfAbsent(c.courseId, () => c.displayTitle);
    lectureParents.putIfAbsent(c.courseId, () => c.parentCourseId);
  }

  // General Quiz collections are tracked separately (Firestore-sourced,
  // per-course) rather than through localCoursesProvider's directory scan —
  // see courses_provider.dart's localCoursesProvider for why they can't
  // share that scan. Each imported collection behaves exactly like a
  // lecture from here on: its collectionId is used as the "lectureId" key
  // throughout, and generalQuizzesProvider reads the identical quizzes.json
  // shape from the identical courses/{id}/ directory convention.
  final generalQuizTitles = <String, String>{};
  final generalQuizParents = <String, String>{};
  for (final course in enrolledCourses) {
    final collections =
        await ref.watch(generalQuizCollectionsProvider(course.courseId).future);
    for (final collection in collections) {
      if (!collection.isImported) continue;
      generalQuizTitles[collection.collectionId] = collection.title;
      generalQuizParents[collection.collectionId] = course.courseId;
    }
  }

  final personalQuizzes = await ref.watch(personalQuizzesProvider.future);

  if (lectureTitles.isEmpty &&
      generalQuizTitles.isEmpty &&
      personalQuizzes.isEmpty) {
    return const [];
  }

  final lectureIds = [
    ...lectureTitles.keys,
    ...generalQuizTitles.keys,
    ...personalQuizzes.map((q) => personalQuizLectureId(q.id)),
  ];
  final srsRows = await QuizDbService.instance.srsRowsForLectures(lectureIds);
  final now = DateTime.now();

  final infos = <ReviewLectureInfo>[];
  for (final lectureId in lectureTitles.keys) {
    final quizzes = await ref.watch(courseQuizzesProvider(lectureId).future);
    final deck = buildReviewDeck(
      quizzesByLecture: {lectureId: quizzes},
      srsRows: srsRows,
      now: now,
    );
    if (deck.totalQuestions == 0) continue; // no reviewable questions
    infos.add(ReviewLectureInfo(
      lectureId: lectureId,
      lectureTitle: lectureTitles[lectureId]!,
      parentCourseId: lectureParents[lectureId] ?? '',
      totalQuestions: deck.totalQuestions,
      dueCount: deck.dueCount,
      nextDueAt: deck.nextDueAt,
    ));
  }
  for (final collectionId in generalQuizTitles.keys) {
    final quizzes =
        await ref.watch(generalQuizzesProvider(collectionId).future);
    final deck = buildReviewDeck(
      quizzesByLecture: {collectionId: quizzes},
      srsRows: srsRows,
      now: now,
    );
    if (deck.totalQuestions == 0) continue;
    infos.add(ReviewLectureInfo(
      lectureId: collectionId,
      lectureTitle: generalQuizTitles[collectionId]!,
      parentCourseId: generalQuizParents[collectionId] ?? '',
      totalQuestions: deck.totalQuestions,
      dueCount: deck.dueCount,
      nextDueAt: deck.nextDueAt,
    ));
  }
  for (final quiz in personalQuizzes) {
    final lectureId = personalQuizLectureId(quiz.id);
    final deck = buildReviewDeck(
      quizzesByLecture: {lectureId: [quiz]},
      srsRows: srsRows,
      now: now,
    );
    if (deck.totalQuestions == 0) continue;
    infos.add(ReviewLectureInfo(
      lectureId: lectureId,
      lectureTitle: quiz.title,
      parentCourseId: kPersonalQuizGroupId,
      totalQuestions: deck.totalQuestions,
      dueCount: deck.dueCount,
      nextDueAt: deck.nextDueAt,
      isPersonalQuiz: true,
    ));
  }
  if (infos.isEmpty) return const [];

  // Course titles: best-effort from the enrolled-courses cache, never awaited.
  final enrolledTitles = <String, String>{
    for (final c in enrolledCourses) c.courseId: c.title,
  };

  final byCourse = <String, List<ReviewLectureInfo>>{};
  for (final info in infos) {
    byCourse.putIfAbsent(info.parentCourseId, () => []).add(info);
  }

  final groups = byCourse.entries
      .map((e) => ReviewCourseGroup(
            parentCourseId: e.key,
            title: e.key == kPersonalQuizGroupId
                ? kPersonalQuizGroupTitle
                : (e.key.isEmpty ? 'Other' : (enrolledTitles[e.key] ?? 'Course')),
            lectures: e.value
              ..sort((a, b) => a.lectureTitle.compareTo(b.lectureTitle)),
          ))
      .toList()
    ..sort((a, b) {
      // Personal quizzes always last, named courses next, 'Other' in between.
      if (a.parentCourseId == kPersonalQuizGroupId ||
          b.parentCourseId == kPersonalQuizGroupId) {
        if (a.parentCourseId == b.parentCourseId) return 0;
        return a.parentCourseId == kPersonalQuizGroupId ? 1 : -1;
      }
      if (a.parentCourseId.isEmpty != b.parentCourseId.isEmpty) {
        return a.parentCourseId.isEmpty ? 1 : -1;
      }
      return a.title.compareTo(b.title);
    });

  return groups;
});

/// Per-lecture summary shown in the starred-questions scope picker — same
/// shape as [ReviewLectureInfo] but counts starred questions instead of due
/// ones (starring has nothing to do with scheduling).
class StarredLectureInfo {
  const StarredLectureInfo({
    required this.lectureId,
    required this.lectureTitle,
    required this.parentCourseId,
    required this.starredCount,
    this.isPersonalQuiz = false,
  });

  final String lectureId;
  final String lectureTitle;
  final String parentCourseId;
  final int starredCount;
  final bool isPersonalQuiz;
}

class StarredCourseGroup {
  const StarredCourseGroup({
    required this.parentCourseId,
    required this.title,
    required this.lectures,
  });

  final String parentCourseId;
  final String title;
  final List<StarredLectureInfo> lectures;

  int get starredCount => lectures.fold(0, (sum, l) => sum + l.starredCount);
}

/// Same source enumeration as [reviewScopeOverviewProvider] (lectures +
/// imported General Quiz collections, grouped by parent course), but counts
/// starred questions via [buildReviewDeck]'s [ReviewFilterMode.starredOnly]
/// filter instead of due/SRS state — a lecture with zero starred questions
/// is left out entirely, same "no reviewable questions" convention.
final starredScopeOverviewProvider =
    FutureProvider.autoDispose<List<StarredCourseGroup>>((ref) async {
  _keepAliveFor(ref, _kReviewOverviewTtl);
  final courses = await ref.watch(localCoursesProvider.future);
  final enrolledCourses = await ref.watch(enrolledCoursesProvider.future);

  final lectureTitles = <String, String>{};
  final lectureParents = <String, String>{};
  for (final c in courses) {
    lectureTitles.putIfAbsent(c.courseId, () => c.displayTitle);
    lectureParents.putIfAbsent(c.courseId, () => c.parentCourseId);
  }

  final generalQuizTitles = <String, String>{};
  final generalQuizParents = <String, String>{};
  for (final course in enrolledCourses) {
    final collections =
        await ref.watch(generalQuizCollectionsProvider(course.courseId).future);
    for (final collection in collections) {
      if (!collection.isImported) continue;
      generalQuizTitles[collection.collectionId] = collection.title;
      generalQuizParents[collection.collectionId] = course.courseId;
    }
  }

  final personalQuizzes = await ref.watch(personalQuizzesProvider.future);

  if (lectureTitles.isEmpty &&
      generalQuizTitles.isEmpty &&
      personalQuizzes.isEmpty) {
    return const [];
  }

  final lectureIds = [
    ...lectureTitles.keys,
    ...generalQuizTitles.keys,
    ...personalQuizzes.map((q) => personalQuizLectureId(q.id)),
  ];
  final starredKeys =
      await QuizDbService.instance.starredKeysForLectures(lectureIds);
  if (starredKeys.isEmpty) return const [];

  final now = DateTime.now();
  final infos = <StarredLectureInfo>[];
  for (final lectureId in lectureTitles.keys) {
    final quizzes = await ref.watch(courseQuizzesProvider(lectureId).future);
    final deck = buildReviewDeck(
      quizzesByLecture: {lectureId: quizzes},
      srsRows: const {},
      now: now,
      filterMode: ReviewFilterMode.starredOnly,
      starredKeys: starredKeys,
    );
    if (deck.totalQuestions == 0) continue;
    infos.add(StarredLectureInfo(
      lectureId: lectureId,
      lectureTitle: lectureTitles[lectureId]!,
      parentCourseId: lectureParents[lectureId] ?? '',
      starredCount: deck.totalQuestions,
    ));
  }
  for (final collectionId in generalQuizTitles.keys) {
    final quizzes =
        await ref.watch(generalQuizzesProvider(collectionId).future);
    final deck = buildReviewDeck(
      quizzesByLecture: {collectionId: quizzes},
      srsRows: const {},
      now: now,
      filterMode: ReviewFilterMode.starredOnly,
      starredKeys: starredKeys,
    );
    if (deck.totalQuestions == 0) continue;
    infos.add(StarredLectureInfo(
      lectureId: collectionId,
      lectureTitle: generalQuizTitles[collectionId]!,
      parentCourseId: generalQuizParents[collectionId] ?? '',
      starredCount: deck.totalQuestions,
    ));
  }
  for (final quiz in personalQuizzes) {
    final lectureId = personalQuizLectureId(quiz.id);
    final deck = buildReviewDeck(
      quizzesByLecture: {lectureId: [quiz]},
      srsRows: const {},
      now: now,
      filterMode: ReviewFilterMode.starredOnly,
      starredKeys: starredKeys,
    );
    if (deck.totalQuestions == 0) continue;
    infos.add(StarredLectureInfo(
      lectureId: lectureId,
      lectureTitle: quiz.title,
      parentCourseId: kPersonalQuizGroupId,
      starredCount: deck.totalQuestions,
      isPersonalQuiz: true,
    ));
  }
  if (infos.isEmpty) return const [];

  final enrolledTitles = <String, String>{
    for (final c in enrolledCourses) c.courseId: c.title,
  };

  final byCourse = <String, List<StarredLectureInfo>>{};
  for (final info in infos) {
    byCourse.putIfAbsent(info.parentCourseId, () => []).add(info);
  }

  final groups = byCourse.entries
      .map((e) => StarredCourseGroup(
            parentCourseId: e.key,
            title: e.key == kPersonalQuizGroupId
                ? kPersonalQuizGroupTitle
                : (e.key.isEmpty ? 'Other' : (enrolledTitles[e.key] ?? 'Course')),
            lectures: e.value
              ..sort((a, b) => a.lectureTitle.compareTo(b.lectureTitle)),
          ))
      .toList()
    ..sort((a, b) {
      if (a.parentCourseId == kPersonalQuizGroupId ||
          b.parentCourseId == kPersonalQuizGroupId) {
        if (a.parentCourseId == b.parentCourseId) return 0;
        return a.parentCourseId == kPersonalQuizGroupId ? 1 : -1;
      }
      if (a.parentCourseId.isEmpty != b.parentCourseId.isEmpty) {
        return a.parentCourseId.isEmpty ? 1 : -1;
      }
      return a.title.compareTo(b.title);
    });

  return groups;
});
