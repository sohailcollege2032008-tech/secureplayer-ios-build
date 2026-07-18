import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'quiz_attempt_result.dart';

class LocalQuizAttempt {
  const LocalQuizAttempt({
    required this.id,
    required this.quizId,
    required this.lectureId,
    required this.quizTitle,
    required this.quizType,
    required this.correctCount,
    required this.totalQuestions,
    required this.totalTimeMs,
    required this.attemptedAt,
    required this.isSynced,
  });

  final int id;
  final String quizId;
  final String lectureId;
  final String quizTitle;
  final String quizType;
  final int correctCount;
  final int totalQuestions;
  final int totalTimeMs;
  final DateTime attemptedAt;
  final bool isSynced;

  String get scoreLabel => '$correctCount / $totalQuestions';

  String get formattedTime {
    final s = totalTimeMs ~/ 1000;
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  factory LocalQuizAttempt.fromMap(Map<String, dynamic> m) => LocalQuizAttempt(
        id: m['id'] as int,
        quizId: m['quiz_id'] as String,
        lectureId: m['lecture_id'] as String,
        quizTitle: m['quiz_title'] as String? ?? '',
        quizType: m['quiz_type'] as String? ?? 'regular',
        correctCount: m['correct_count'] as int? ?? 0,
        totalQuestions: m['total_questions'] as int? ?? 0,
        totalTimeMs: m['total_time_ms'] as int? ?? 0,
        attemptedAt: DateTime.fromMillisecondsSinceEpoch(
            m['attempted_at'] as int? ?? 0),
        isSynced: (m['is_synced'] as int? ?? 0) == 1,
      );
}

class QuizHistoryService {
  static Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dbDir = await getDatabasesPath();
    final dbPath = '$dbDir/quiz_history.db';
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE quiz_attempts (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            quiz_id       TEXT NOT NULL,
            lecture_id    TEXT NOT NULL,
            quiz_title    TEXT,
            quiz_type     TEXT,
            correct_count INTEGER,
            total_questions INTEGER,
            total_time_ms INTEGER,
            attempted_at  INTEGER,
            is_synced     INTEGER DEFAULT 0
          )
        ''');
      },
    );
    return _db!;
  }

  Future<bool> isFirstAttempt(String quizId) async {
    final db = await _database;
    final rows = await db.query(
      'quiz_attempts',
      where: 'quiz_id = ?',
      whereArgs: [quizId],
      limit: 1,
    );
    return rows.isEmpty;
  }

  Future<void> insertAttempt(QuizAttemptResult r) async {
    final db = await _database;
    await db.insert('quiz_attempts', {
      'quiz_id': r.quiz.id,
      'lecture_id': r.lectureId,
      'quiz_title': r.quiz.title,
      'quiz_type': r.quiz.isPopupQuiz ? 'inline_popup' : 'regular',
      'correct_count': r.correctCount,
      'total_questions': r.totalQuestions,
      'total_time_ms': r.totalTimeMs,
      'attempted_at': DateTime.now().millisecondsSinceEpoch,
      'is_synced': 0,
    });
  }

  Future<LocalQuizAttempt?> getLatestAttempt(String quizId) async {
    final db = await _database;
    final rows = await db.query(
      'quiz_attempts',
      where: 'quiz_id = ?',
      whereArgs: [quizId],
      orderBy: 'attempted_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LocalQuizAttempt.fromMap(rows.first);
  }

  Future<List<LocalQuizAttempt>> getAttemptsByLecture(
      String lectureId) async {
    final db = await _database;
    final rows = await db.query(
      'quiz_attempts',
      where: 'lecture_id = ?',
      whereArgs: [lectureId],
      orderBy: 'attempted_at DESC',
    );
    return rows.map(LocalQuizAttempt.fromMap).toList();
  }

  Future<List<LocalQuizAttempt>> getAllAttempts() async {
    final db = await _database;
    final rows = await db.query(
      'quiz_attempts',
      orderBy: 'attempted_at DESC',
    );
    return rows.map(LocalQuizAttempt.fromMap).toList();
  }
}

final quizHistoryServiceProvider =
    Provider<QuizHistoryService>((ref) => QuizHistoryService());

final allQuizAttemptsProvider =
    FutureProvider<List<LocalQuizAttempt>>((ref) async {
  return ref.read(quizHistoryServiceProvider).getAllAttempts();
});

/// All attempts of one quiz, grouped for side-by-side comparison in the
/// My Quizzes screen. [attempts] stays in the source query's newest-first
/// order.
class GroupedQuizAttempts {
  const GroupedQuizAttempts({
    required this.quizId,
    required this.quizTitle,
    required this.attempts,
  });

  final String quizId;
  final String quizTitle;
  final List<LocalQuizAttempt> attempts;

  int get attemptCount => attempts.length;
  LocalQuizAttempt get mostRecent => attempts.first;
}

/// allQuizAttemptsProvider's flat list, bucketed by quiz_id. Groups are
/// ordered by each group's most recent attempt (same overall recency
/// ordering the flat list already had).
final groupedQuizAttemptsProvider =
    FutureProvider<List<GroupedQuizAttempts>>((ref) async {
  final attempts = await ref.watch(allQuizAttemptsProvider.future);
  final byQuiz = <String, List<LocalQuizAttempt>>{};
  for (final a in attempts) {
    byQuiz.putIfAbsent(a.quizId, () => []).add(a);
  }
  final groups = byQuiz.entries
      .map((e) => GroupedQuizAttempts(
            quizId: e.key,
            quizTitle: e.value.first.quizTitle,
            attempts: e.value,
          ))
      .toList()
    ..sort((a, b) => b.mostRecent.attemptedAt.compareTo(a.mostRecent.attemptedAt));
  return groups;
});
