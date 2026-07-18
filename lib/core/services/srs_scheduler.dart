/// Pure-Dart spaced-repetition scheduler (FSRS-lite).
///
/// No Flutter/sqflite imports — unit-testable in isolation. The ladder is
/// intentionally simple: each rating maps to a next interval that grows with
/// successful repetitions (hard grows least, easy most; only "again" resets)
/// — this matches real FSRS's qualitative shape (verified against FSRS
/// documentation: Hard/Good/Easy are all successful-recall ratings that grow
/// the interval, only a genuine lapse shrinks it). Exact numbers are tunable
/// per-student via [ReviewSettings], which also carries the one addition
/// beyond the base ladder: a "desired retention" percentage that globally
/// scales every computed interval, mirroring real FSRS's retention slider.
library;

import 'dart:math' show pow;

import '../models/review_settings.dart';

/// Student's self-rating after answering a review question.
/// Persisted to SQLite as [ReviewRating.index] — do NOT reorder members.
enum ReviewRating { again, hard, medium, easy }

/// Next scheduling state produced by applying a rating.
class SrsState {
  const SrsState({
    required this.reps,
    required this.intervalMin,
    required this.dueAt,
  });

  final int reps;
  final double intervalMin;
  final DateTime dueAt;
}

/// A persisted row from the `question_srs` table. Lives here (not in the DB
/// service) so the pure deck builder can consume it without importing sqflite.
class SrsRow {
  const SrsRow({
    required this.questionId,
    required this.quizId,
    required this.lectureId,
    required this.courseId,
    required this.reps,
    required this.intervalMin,
    required this.dueAt,
    this.lastRating,
    this.lastReviewed,
  });

  final String questionId;
  final String quizId;
  final String lectureId;
  final String courseId;
  final int reps;
  final double intervalMin;
  final DateTime dueAt;
  final int? lastRating; // ReviewRating.index
  final DateTime? lastReviewed;

  /// Key used across the deck builder and DB maps.
  String get key => '$questionId::$quizId';
}

class SrsScheduler {
  SrsScheduler._();

  /// Applies [rating] to the previous state ([reps]/[intervalMin] are 0/0 for
  /// a never-reviewed question) and returns the next state, using [settings]
  /// for both the base ladder tuning and the retention scale.
  static SrsState next({
    required int reps,
    required double intervalMin,
    required ReviewRating rating,
    required DateTime now,
    required ReviewSettings settings,
  }) {
    final int nextReps;
    double nextInterval;

    switch (rating) {
      case ReviewRating.again:
        nextReps = 0;
        nextInterval = settings.wrongIntervalMin;
      case ReviewRating.hard:
        nextReps = reps;
        nextInterval = intervalMin * settings.hardMultiplier;
        if (nextInterval < settings.hardFloorMin) {
          nextInterval = settings.hardFloorMin;
        }
      case ReviewRating.medium:
        nextReps = reps + 1;
        nextInterval = reps == 0
            ? settings.mediumFirstMin
            : intervalMin * settings.mediumMultiplier;
      case ReviewRating.easy:
        nextReps = reps + 1;
        nextInterval = reps == 0
            ? settings.easyFirstMin
            : intervalMin * settings.easyMultiplier;
    }

    nextInterval *= retentionScale(settings.retentionPercent);

    if (nextInterval > settings.maxIntervalMin) {
      nextInterval = settings.maxIntervalMin;
    }

    return SrsState(
      reps: nextReps,
      intervalMin: nextInterval,
      dueAt: now.add(Duration(seconds: (nextInterval * 60).round())),
    );
  }

  /// Desired-retention scaling factor applied to every computed interval —
  /// neutral (1.0) at the 90% default, shorter above, longer below, matching
  /// real FSRS's "higher retention -> shorter intervals, more frequent
  /// review" relationship. The exact curve is a tunable constant, not a
  /// faithful reproduction of FSRS's own stability-based formula (this app
  /// has no per-question stability/difficulty model to drive that).
  static double retentionScale(double retentionPercent) =>
      pow(2, (90 - retentionPercent) / 20).toDouble();

  /// Compact human label: "1m", "45m", "2.2h", "3d".
  static String formatInterval(double minutes) {
    if (minutes < 60) {
      return '${minutes.round()}m';
    }
    final hours = minutes / 60;
    if (hours < 24) {
      final rounded = (hours * 10).round() / 10;
      return rounded == rounded.roundToDouble()
          ? '${rounded.round()}h'
          : '${rounded}h';
    }
    final days = hours / 24;
    return '${days.round()}d';
  }
}
