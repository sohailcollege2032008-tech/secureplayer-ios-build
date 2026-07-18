import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/services/firestore_rest.dart';
import '../auth/auth_providers.dart';

class EnrolledCourse {
  const EnrolledCourse({
    required this.courseId,
    required this.title,
    this.description = '',
    this.coverImageUrl,
    this.coverImageVersion = 0,
  });

  final String courseId;
  final String title;
  final String description;
  final String? coverImageUrl;
  // Studio writes a new version tag on every re-upload (same convention it
  // uses for its own preview, `cover_image_version` in Firestore). Without
  // it, CachedNetworkImage's default cache key is the URL string — if a
  // teacher re-uploads a cover to the same R2 key, the student app would
  // keep serving whatever was cached under that URL (a stale image, or a
  // cached failure) forever.
  final int coverImageVersion;

  Map<String, dynamic> toJson() => {
        'courseId': courseId,
        'title': title,
        'description': description,
        'coverImageUrl': coverImageUrl,
        'coverImageVersion': coverImageVersion,
      };

  factory EnrolledCourse.fromJson(Map<String, dynamic> json) => EnrolledCourse(
        courseId: json['courseId'] as String,
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        coverImageUrl: json['coverImageUrl'] as String?,
        coverImageVersion: (json['coverImageVersion'] as num?)?.toInt() ?? 0,
      );
}

class LectureSummary {
  const LectureSummary({
    required this.lectureId,
    required this.courseId,
    required this.title,
    this.videoCount = 0,
    this.durationSeconds = 0,
    this.isImported = false,
  });

  final String lectureId;
  final String courseId;
  final String title;
  final int videoCount;
  final int durationSeconds;
  final bool isImported;

  String get formattedDuration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}

const _kEnrolledCoursesCacheSchemaVersion = 1;
const _kEnrolledCoursesCacheTtl = Duration(minutes: 5);

Future<File> _enrolledCoursesCacheFile() async {
  final appDir = await getApplicationSupportDirectory();
  final dir = Directory('${appDir.path}/cache');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return File('${dir.path}/enrolled_courses.json');
}

/// Deletes the on-disk cache so the next [enrolledCoursesProvider] read hits
/// Firestore live instead of a within-TTL stale cache. Call this before any
/// explicit user-requested refresh (pull-to-refresh, the error screen's
/// Retry button) alongside `ref.invalidate`/`ref.refresh` — otherwise a
/// refresh within 5 minutes of the last fetch would just re-serve the same
/// cached list and look like nothing happened.
Future<void> invalidateEnrolledCoursesCache() async {
  try {
    final file = await _enrolledCoursesCacheFile();
    if (file.existsSync()) await file.delete();
  } catch (_) {
    // Best-effort — a failed delete just means the next read may still
    // serve a stale cache for the rest of its TTL, not a correctness bug.
  }
}

/// Returns the cached list if present, schema-current, and within TTL —
/// null otherwise (including on any parse error, e.g. a future release
/// changing EnrolledCourse's shape and finding an older cache file on disk;
/// falling through to a live fetch is always safe, so any doubt here just
/// returns null rather than risking a bad deserialize).
Future<List<EnrolledCourse>?> _readEnrolledCoursesCache() async {
  try {
    final file = await _enrolledCoursesCacheFile();
    if (!file.existsSync()) return null;
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (raw['schemaVersion'] != _kEnrolledCoursesCacheSchemaVersion) return null;
    final fetchedAt = DateTime.tryParse(raw['fetchedAt'] as String? ?? '');
    if (fetchedAt == null) return null;
    if (DateTime.now().difference(fetchedAt) > _kEnrolledCoursesCacheTtl) return null;
    final list = raw['courses'] as List?;
    if (list == null) return null;
    return list
        .map((e) => EnrolledCourse.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return null;
  }
}

Future<void> _writeEnrolledCoursesCache(List<EnrolledCourse> courses) async {
  try {
    final file = await _enrolledCoursesCacheFile();
    final payload = jsonEncode({
      'schemaVersion': _kEnrolledCoursesCacheSchemaVersion,
      'fetchedAt': DateTime.now().toIso8601String(),
      'courses': courses.map((c) => c.toJson()).toList(),
    });
    await file.writeAsString(payload);
  } catch (_) {
    // Best-effort — a failed cache write just means the next read fetches
    // live again, not a correctness bug.
  }
}

Future<List<EnrolledCourse>> _fetchEnrolledCoursesLive(String uid) async {
  // A student's own enrollment count is bounded by what one person can
  // realistically enroll in (unlike the owner's platform-wide student list),
  // so a generous safety cap — not full cursor pagination — is enough to
  // avoid a pathological account with an unbounded number of docs blowing up
  // this read.
  final enrollDocs = await FirestoreRest.instance.queryAnd(
    'enrollments',
    [
      (field: 'student_uid', op: 'EQUAL', value: uid),
      (field: 'is_active', op: 'EQUAL', value: true),
    ],
    limit: 200,
  );

  if (enrollDocs.isEmpty) return [];

  final courseIds = enrollDocs
      .map((r) => r.data['course_id'] as String?)
      .whereType<String>()
      .toSet()
      .toList();

  final courseDocs = await Future.wait(
      courseIds.map((id) => FirestoreRest.instance.getDoc('courses', id)));

  final result = <EnrolledCourse>[];
  for (var i = 0; i < courseIds.length; i++) {
    final data = courseDocs[i];
    if (data == null) continue;
    if (data['is_deleted'] as bool? ?? false) continue;
    result.add(EnrolledCourse(
      courseId: courseIds[i],
      title: data['title'] as String? ?? courseIds[i],
      description: data['description'] as String? ?? '',
      coverImageUrl: data['cover_image_url'] as String?,
      coverImageVersion: (data['cover_image_version'] as num?)?.toInt() ?? 0,
    ));
  }
  result.sort((a, b) => a.title.compareTo(b.title));
  return result;
}

/// Fetches all courses the current student is actively enrolled in. Served
/// from a 5-minute on-disk TTL cache when fresh — every cold start / hot
/// restart during a testing session was previously re-running the full
/// 1-query + N-getDoc-per-course sequence from zero, the single biggest
/// driver of a heavy dev day's read count. Explicit refreshes must call
/// [invalidateEnrolledCoursesCache] first so they always hit Firestore live.
final enrolledCoursesProvider =
    FutureProvider<List<EnrolledCourse>>((ref) async {
  final user = ref.watch(authStateChangesProvider).valueOrNull;
  if (user == null) return [];

  final cached = await _readEnrolledCoursesCache();
  if (cached != null) return cached;

  final result = await _fetchEnrolledCoursesLive(user.uid);
  unawaited(_writeEnrolledCoursesCache(result));
  return result;
});

/// Fetches lectures for a course from Firestore + checks local import status.
/// Kept as a plain full-list fetch (not paginated) — review_providers.dart's
/// review-scope aggregation needs the *complete* set of a course's lectures,
/// which a partial page can't answer correctly. Only the browsing UI
/// (course_lectures_screen.dart) needed pagination — see
/// fetchCourseLecturesPage below for that.
final courseLecturesProvider =
    FutureProvider.family<List<LectureSummary>, String>((ref, courseId) async {
  final appDir = await getApplicationSupportDirectory();

  final lectureDocs = await FirestoreRest.instance
      .query('lectures', whereField: 'course_id', whereValue: courseId);

  final summaries = await Future.wait(lectureDocs.map((r) async {
    final data = r.data;
    final lectureId = r.id;
    final metaFile =
        File('${appDir.path}/courses/$lectureId/metadata.json');
    final isImported = await metaFile.exists();

    return LectureSummary(
      lectureId: lectureId,
      courseId: courseId,
      title: data['title'] as String? ?? lectureId,
      videoCount: (data['video_count'] as num?)?.toInt() ?? 0,
      durationSeconds: (data['duration_seconds'] as num?)?.toInt() ?? 0,
      isImported: isImported,
    );
  }));

  summaries.sort((a, b) => a.title.compareTo(b.title));
  return summaries;
});

const _lecturesPageSize = 20;

typedef CreatedAtCursor = ({String docId, DateTime createdAt});

class LecturesPage {
  const LecturesPage({required this.items, required this.nextCursor});
  final List<LectureSummary> items;
  final CreatedAtCursor? nextCursor;
}

/// Cursor-paginated, newest-created-first — what course_lectures_screen.dart
/// actually scrolls. courseLecturesProvider above stays unpaginated
/// on purpose for the review-scope aggregation use.
Future<LecturesPage> fetchCourseLecturesPage({
  required String courseId,
  CreatedAtCursor? after,
}) async {
  final appDir = await getApplicationSupportDirectory();
  final docs = await FirestoreRest.instance.queryAnd(
    'lectures',
    [(field: 'course_id', op: 'EQUAL', value: courseId)],
    limit: _lecturesPageSize,
    orderByField: 'created_at',
    descending: true,
    after: after == null ? null : (docId: after.docId, fieldValue: after.createdAt),
  );

  final items = await Future.wait(docs.map((r) async {
    final data = r.data;
    final lectureId = r.id;
    final metaFile = File('${appDir.path}/courses/$lectureId/metadata.json');
    final isImported = await metaFile.exists();
    return LectureSummary(
      lectureId: lectureId,
      courseId: courseId,
      title: data['title'] as String? ?? lectureId,
      videoCount: (data['video_count'] as num?)?.toInt() ?? 0,
      durationSeconds: (data['duration_seconds'] as num?)?.toInt() ?? 0,
      isImported: isImported,
    );
  }));

  final nextCursor = docs.length == _lecturesPageSize
      ? (
          docId: docs.last.id,
          createdAt: (docs.last.data['created_at'] as DateTime?) ?? DateTime.now(),
        )
      : null;
  return LecturesPage(items: items, nextCursor: nextCursor);
}

class GeneralQuizCollectionSummary {
  const GeneralQuizCollectionSummary({
    required this.collectionId,
    required this.courseId,
    required this.title,
    this.questionCount = 0,
    this.isImported = false,
  });

  final String collectionId;
  final String courseId;
  final String title;
  final int questionCount;
  final bool isImported;
}

/// Fetches General Quiz collections for a course from Firestore + checks
/// local import status — mirrors courseLecturesProvider exactly. A
/// collection is "imported" once its .secquiz has been extracted to
/// courses/{collectionId}/ (same directory convention as a lecture, so the
/// existing shelf server / secure storage key lookup work unchanged).
final generalQuizCollectionsProvider = FutureProvider.family<
    List<GeneralQuizCollectionSummary>, String>((ref, courseId) async {
  final appDir = await getApplicationSupportDirectory();

  final docs = await FirestoreRest.instance
      .query('general_quizzes', whereField: 'course_id', whereValue: courseId);

  final summaries = await Future.wait(docs.map((r) async {
    final data = r.data;
    final collectionId = r.id;
    final metaFile =
        File('${appDir.path}/courses/$collectionId/metadata.json');
    final isImported = await metaFile.exists();

    return GeneralQuizCollectionSummary(
      collectionId: collectionId,
      courseId: courseId,
      title: data['title'] as String? ?? collectionId,
      questionCount: (data['question_count'] as num?)?.toInt() ?? 0,
      isImported: isImported,
    );
  }));

  summaries.sort((a, b) => a.title.compareTo(b.title));
  return summaries;
});

const _generalQuizzesPageSize = 20;

class GeneralQuizzesPage {
  const GeneralQuizzesPage({required this.items, required this.nextCursor});
  final List<GeneralQuizCollectionSummary> items;
  final CreatedAtCursor? nextCursor;
}

/// Cursor-paginated counterpart to fetchCourseLecturesPage, same rationale —
/// generalQuizCollectionsProvider above stays unpaginated for
/// review_providers.dart's aggregation use.
Future<GeneralQuizzesPage> fetchCourseGeneralQuizzesPage({
  required String courseId,
  CreatedAtCursor? after,
}) async {
  final appDir = await getApplicationSupportDirectory();
  final docs = await FirestoreRest.instance.queryAnd(
    'general_quizzes',
    [(field: 'course_id', op: 'EQUAL', value: courseId)],
    limit: _generalQuizzesPageSize,
    orderByField: 'created_at',
    descending: true,
    after: after == null ? null : (docId: after.docId, fieldValue: after.createdAt),
  );

  final items = await Future.wait(docs.map((r) async {
    final data = r.data;
    final collectionId = r.id;
    final metaFile = File('${appDir.path}/courses/$collectionId/metadata.json');
    final isImported = await metaFile.exists();
    return GeneralQuizCollectionSummary(
      collectionId: collectionId,
      courseId: courseId,
      title: data['title'] as String? ?? collectionId,
      questionCount: (data['question_count'] as num?)?.toInt() ?? 0,
      isImported: isImported,
    );
  }));

  final nextCursor = docs.length == _generalQuizzesPageSize
      ? (
          docId: docs.last.id,
          createdAt: (docs.last.data['created_at'] as DateTime?) ?? DateTime.now(),
        )
      : null;
  return GeneralQuizzesPage(items: items, nextCursor: nextCursor);
}
