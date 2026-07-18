import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

import '../models/quiz.dart';
import '../models/quiz_progress.dart';
import 'srs_scheduler.dart';

/// Persistent local SQLite storage for quiz attempts, starred questions,
/// and SRS review scheduling. Zero Firestore dependency.
class QuizDbService {
  QuizDbService._();
  static final QuizDbService instance = QuizDbService._();

  Database? _db;

  /// Pre-warms the DB connection. Call once in main() after sqflite FFI init.
  Future<void> init() async {
    _db ??= await _open();
  }

  Future<Database> get _database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/quiz_srs.db';
    return openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE question_attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        question_id TEXT NOT NULL,
        quiz_id TEXT NOT NULL,
        lecture_id TEXT NOT NULL,
        course_id TEXT NOT NULL,
        is_correct INTEGER NOT NULL,
        selected_index INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        weight INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_attempts_course ON question_attempts (course_id, question_id)
    ''');

    await db.execute('''
      CREATE TABLE starred_questions (
        question_id TEXT NOT NULL,
        quiz_id TEXT NOT NULL,
        lecture_id TEXT NOT NULL,
        course_id TEXT NOT NULL,
        starred_at INTEGER NOT NULL,
        PRIMARY KEY (question_id, quiz_id)
      )
    ''');

    await _createSrsTable(db);
    await _createQuizProgressTable(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSrsTable(db);
    }
    if (oldVersion < 3) {
      await _createQuizProgressTable(db);
    }
  }

  static Future<void> _createSrsTable(Database db) async {
    await db.execute('''
      CREATE TABLE question_srs (
        question_id TEXT NOT NULL,
        quiz_id TEXT NOT NULL,
        lecture_id TEXT NOT NULL,
        course_id TEXT NOT NULL,
        reps INTEGER NOT NULL DEFAULT 0,
        interval_min REAL NOT NULL DEFAULT 0,
        due_at INTEGER NOT NULL,
        last_rating INTEGER,
        last_reviewed INTEGER,
        PRIMARY KEY (question_id, quiz_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_srs_lecture_due ON question_srs (lecture_id, due_at)
    ''');
  }

  /// In-progress quiz attempts, keyed like the router addresses a quiz
  /// (/quiz/:lectureId/:quizId) — nothing in the codebase guarantees quiz.id
  /// is globally unique on its own. JSON-blob TEXT columns for the
  /// order/answers/times arrays: always read/written as one atomic unit,
  /// never queried by their contents, matching how quizzes.json etc. are
  /// already whole-file JSON blobs elsewhere in this app.
  static Future<void> _createQuizProgressTable(Database db) async {
    await db.execute('''
      CREATE TABLE quiz_progress (
        quiz_id TEXT NOT NULL,
        lecture_id TEXT NOT NULL,
        video_id TEXT,
        layout_mode TEXT NOT NULL,
        question_order TEXT NOT NULL,
        option_orders TEXT NOT NULL,
        answers_by_index TEXT NOT NULL,
        times_by_index TEXT NOT NULL,
        current_index INTEGER NOT NULL DEFAULT 0,
        start_time_ms INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (quiz_id, lecture_id)
      )
    ''');
  }

  // ─── Record an attempt ──────────────────────────────────────────────────────

  /// Logs one question answer to history (question_attempts). Never touches
  /// SRS scheduling state itself — that's written exclusively by
  /// ReviewSyncService.syncAttemptToReview() (quiz-attempt sync, gated to
  /// first-attempt-or-confirmed-retake) or ReviewSessionScreen._rate()
  /// (genuine review-session ratings). Splitting these apart is what fixes
  /// the previous bug where every single quiz attempt — first try or
  /// fiftieth retake — silently overwrote each question's due date.
  Future<void> recordAttempt({
    required QuizQuestion question,
    required String quizId,
    required String lectureId,
    required String courseId,
    required int selectedIndex,
  }) async {
    final db = await _database;
    final isCorrect = selectedIndex == question.correctIndex ? 1 : 0;
    final weight = isCorrect == 1 ? 1 : 3;

    await db.insert(
      'question_attempts',
      {
        'question_id': question.id,
        'quiz_id': quizId,
        'lecture_id': lectureId,
        'course_id': courseId,
        'is_correct': isCorrect,
        'selected_index': selectedIndex,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'weight': weight,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Deletes every SRS row for one quiz — the "prune" half of a full
  /// resync (see ReviewSyncService.syncAttemptToReview()), which always
  /// follows this with fresh inserts for whichever questions the sync's
  /// chosen scope includes.
  Future<void> deleteSrsForQuiz(String quizId) async {
    final db = await _database;
    await db.delete('question_srs', where: 'quiz_id = ?', whereArgs: [quizId]);
  }

  // ─── Starred questions ──────────────────────────────────────────────────────

  Future<void> starQuestion({
    required String questionId,
    required String quizId,
    required String lectureId,
    required String courseId,
  }) async {
    final db = await _database;
    await db.insert(
      'starred_questions',
      {
        'question_id': questionId,
        'quiz_id': quizId,
        'lecture_id': lectureId,
        'course_id': courseId,
        'starred_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> unstarQuestion(String questionId, String quizId) async {
    final db = await _database;
    await db.delete(
      'starred_questions',
      where: 'question_id = ? AND quiz_id = ?',
      whereArgs: [questionId, quizId],
    );
  }

  Future<bool> isStarred(String questionId, String quizId) async {
    final db = await _database;
    final rows = await db.query(
      'starred_questions',
      where: 'question_id = ? AND quiz_id = ?',
      whereArgs: [questionId, quizId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<Set<String>> starredQuestionIds(String courseId) async {
    final db = await _database;
    final rows = await db.query(
      'starred_questions',
      columns: ['question_id'],
      where: 'course_id = ?',
      whereArgs: [courseId],
    );
    return rows.map((r) => r['question_id'] as String).toSet();
  }

  /// Starred question keys across multiple lectures, formatted
  /// "{questionId}::{quizId}" (same composite-key shape as SrsRow.key /
  /// buildReviewDeck's starredKeys) — a plain question_id set would collide
  /// across different quizzes that happen to share a question id.
  Future<Set<String>> starredKeysForLectures(List<String> lectureIds) async {
    if (lectureIds.isEmpty) return {};
    final db = await _database;
    final placeholders = List.filled(lectureIds.length, '?').join(',');
    final rows = await db.query(
      'starred_questions',
      columns: ['question_id', 'quiz_id'],
      where: 'lecture_id IN ($placeholders)',
      whereArgs: lectureIds,
    );
    return rows.map((r) => '${r['question_id']}::${r['quiz_id']}').toSet();
  }

  // ─── Last attempt per question ──────────────────────────────────────────────

  Future<Map<String, bool>> lastAttemptsForCourse(String courseId) async {
    final db = await _database;
    // Get the most recent attempt per question for this course
    final rows = await db.rawQuery('''
      SELECT question_id, is_correct
      FROM question_attempts
      WHERE course_id = ?
        AND id IN (
          SELECT MAX(id) FROM question_attempts
          WHERE course_id = ?
          GROUP BY question_id
        )
    ''', [courseId, courseId]);
    return {
      for (final r in rows)
        r['question_id'] as String: (r['is_correct'] as int) == 1
    };
  }

  Future<Map<String, bool>> lastAttemptsForLecture(String lectureId) async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT question_id, is_correct
      FROM question_attempts
      WHERE lecture_id = ?
        AND id IN (
          SELECT MAX(id) FROM question_attempts
          WHERE lecture_id = ?
          GROUP BY question_id
        )
    ''', [lectureId, lectureId]);
    return {
      for (final r in rows)
        r['question_id'] as String: (r['is_correct'] as int) == 1
    };
  }

  // ─── SRS scheduling state ───────────────────────────────────────────────────

  /// All SRS rows for the given lectures, keyed `"{questionId}::{quizId}"`.
  /// Single query so a whole-course scope doesn't fan out per lecture.
  Future<Map<String, SrsRow>> srsRowsForLectures(
      List<String> lectureIds) async {
    if (lectureIds.isEmpty) return {};
    final db = await _database;
    final placeholders = List.filled(lectureIds.length, '?').join(',');
    final rows = await db.query(
      'question_srs',
      where: 'lecture_id IN ($placeholders)',
      whereArgs: lectureIds,
    );
    final result = <String, SrsRow>{};
    for (final r in rows) {
      final row = SrsRow(
        questionId: r['question_id'] as String,
        quizId: r['quiz_id'] as String,
        lectureId: r['lecture_id'] as String,
        courseId: r['course_id'] as String,
        reps: (r['reps'] as num).toInt(),
        intervalMin: (r['interval_min'] as num).toDouble(),
        dueAt:
            DateTime.fromMillisecondsSinceEpoch((r['due_at'] as num).toInt()),
        lastRating: (r['last_rating'] as num?)?.toInt(),
        lastReviewed: r['last_reviewed'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (r['last_reviewed'] as num).toInt())
            : null,
      );
      result[row.key] = row;
    }
    return result;
  }

  /// A single question's SRS row, or null if never scheduled. Cheaper than
  /// srsRowsForLectures() when only one question needs grading (e.g. right
  /// after a regular quiz attempt) — same (question_id, quiz_id) primary key,
  /// no new index needed.
  Future<SrsRow?> srsRowForQuestion(String questionId, String quizId) async {
    final db = await _database;
    final rows = await db.query(
      'question_srs',
      where: 'question_id = ? AND quiz_id = ?',
      whereArgs: [questionId, quizId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return SrsRow(
      questionId: r['question_id'] as String,
      quizId: r['quiz_id'] as String,
      lectureId: r['lecture_id'] as String,
      courseId: r['course_id'] as String,
      reps: (r['reps'] as num).toInt(),
      intervalMin: (r['interval_min'] as num).toDouble(),
      dueAt: DateTime.fromMillisecondsSinceEpoch((r['due_at'] as num).toInt()),
      lastRating: (r['last_rating'] as num?)?.toInt(),
      lastReviewed: r['last_reviewed'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (r['last_reviewed'] as num).toInt())
          : null,
    );
  }

  /// Insert-or-replace a question's SRS state after the student rates it.
  Future<void> upsertSrsState({
    required String questionId,
    required String quizId,
    required String lectureId,
    required String courseId,
    required SrsState next,
    required ReviewRating rating,
    required DateTime reviewedAt,
  }) async {
    final db = await _database;
    await db.insert(
      'question_srs',
      {
        'question_id': questionId,
        'quiz_id': quizId,
        'lecture_id': lectureId,
        'course_id': courseId,
        'reps': next.reps,
        'interval_min': next.intervalMin,
        'due_at': next.dueAt.millisecondsSinceEpoch,
        'last_rating': rating.index,
        'last_reviewed': reviewedAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ─── In-progress quiz resume ────────────────────────────────────────────────

  Future<void> saveQuizProgress(QuizProgressRow row) async {
    final db = await _database;
    await db.insert(
      'quiz_progress',
      row.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<QuizProgressRow?> loadQuizProgress(
      String quizId, String lectureId) async {
    final db = await _database;
    final rows = await db.query(
      'quiz_progress',
      where: 'quiz_id = ? AND lecture_id = ?',
      whereArgs: [quizId, lectureId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return QuizProgressRow.fromMap(rows.first);
  }

  Future<void> deleteQuizProgress(String quizId, String lectureId) async {
    final db = await _database;
    await db.delete(
      'quiz_progress',
      where: 'quiz_id = ? AND lecture_id = ?',
      whereArgs: [quizId, lectureId],
    );
  }

  // ─── Stats ──────────────────────────────────────────────────────────────────

  Future<QuizStats> statsForCourse(String courseId) async {
    final db = await _database;
    final total = await db.rawQuery('''
      SELECT COUNT(DISTINCT question_id) as cnt FROM question_attempts
      WHERE course_id = ?
    ''', [courseId]);
    final wrong = await db.rawQuery('''
      SELECT COUNT(*) as cnt FROM (
        SELECT question_id, is_correct
        FROM question_attempts
        WHERE course_id = ?
          AND id IN (
            SELECT MAX(id) FROM question_attempts
            WHERE course_id = ? GROUP BY question_id
          )
      ) WHERE is_correct = 0
    ''', [courseId, courseId]);
    final starredCount = await db.rawQuery('''
      SELECT COUNT(*) as cnt FROM starred_questions WHERE course_id = ?
    ''', [courseId]);

    return QuizStats(
      attempted: (total.first['cnt'] as int?) ?? 0,
      wrong: (wrong.first['cnt'] as int?) ?? 0,
      starred: (starredCount.first['cnt'] as int?) ?? 0,
    );
  }
}

class QuizStats {
  const QuizStats({
    required this.attempted,
    required this.wrong,
    required this.starred,
  });

  final int attempted;
  final int wrong;
  final int starred;
}
