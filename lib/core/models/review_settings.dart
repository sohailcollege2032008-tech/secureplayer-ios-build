/// Student-facing spaced-repetition review preferences. Global (not
/// per-course/per-quiz), persisted via SharedPreferences — see
/// review_settings_service.dart.
///
/// Defaults mirror Anki's real scheduling constants: relearning step (10m),
/// minimum interval (1d), graduating interval (1d), starting ease (250%),
/// hard interval multiplier (120%). `easyFirstMin` deliberately deviates
/// from Anki's literal 4-day new-card-only Easy interval — in this app the
/// reps==0 flat branches only ever fire for a wrong/starred question freshly
/// reset via syncAttemptToReview, not Anki's "skip straight past learning"
/// flow, so using Anki's generous new-card figure here would make a
/// freshly-reset wrong/starred question's first "easy" land later than a
/// plain-correct question's first "easy" — inverting the intended "wrong or
/// starred resurfaces sooner" behavior.
class ReviewSettings {
  const ReviewSettings({
    this.wrongIntervalMin = 10,
    this.hardFloorMin = 1440,
    this.hardMultiplier = 1.2,
    this.mediumFirstMin = 1440,
    this.mediumMultiplier = 2.5,
    this.easyFirstMin = 2160,
    this.easyMultiplier = 3.25,
    this.maxIntervalMin = 60.0 * 24 * 60,
    this.retentionPercent = 90,
    this.cooldownSeconds = 60,
  });

  // "Again" — flat reset interval, no growth from any prior state.
  final double wrongIntervalMin;
  // "Hard" — smallest growth of the three successful ratings; floored so
  // repeated hards on a very short interval still make meaningful progress.
  final double hardFloorMin;
  final double hardMultiplier;
  // "Medium"/"Good" — moderate growth; uses the flat first-time value only
  // when there's no prior interval to grow from.
  final double mediumFirstMin;
  final double mediumMultiplier;
  // "Easy" — largest growth.
  final double easyFirstMin;
  final double easyMultiplier;
  // Ceiling so no interval schedules further than this out.
  final double maxIntervalMin;
  // 0-100. Desired retention: scales every computed interval — higher means
  // shorter intervals (reviewed more often), lower means longer. 90 is
  // neutral (matches today's un-scaled behavior).
  final double retentionPercent;
  // Minimum wall-clock delay before a question graded in this same review
  // session can be shown again (e.g. after an "again" rating).
  final int cooldownSeconds;

  static const double minRetentionPercent = 50;
  static const double maxRetentionPercent = 100;

  ReviewSettings copyWith({
    double? wrongIntervalMin,
    double? hardFloorMin,
    double? hardMultiplier,
    double? mediumFirstMin,
    double? mediumMultiplier,
    double? easyFirstMin,
    double? easyMultiplier,
    double? maxIntervalMin,
    double? retentionPercent,
    int? cooldownSeconds,
  }) {
    return ReviewSettings(
      wrongIntervalMin: wrongIntervalMin ?? this.wrongIntervalMin,
      hardFloorMin: hardFloorMin ?? this.hardFloorMin,
      hardMultiplier: hardMultiplier ?? this.hardMultiplier,
      mediumFirstMin: mediumFirstMin ?? this.mediumFirstMin,
      mediumMultiplier: mediumMultiplier ?? this.mediumMultiplier,
      easyFirstMin: easyFirstMin ?? this.easyFirstMin,
      easyMultiplier: easyMultiplier ?? this.easyMultiplier,
      maxIntervalMin: maxIntervalMin ?? this.maxIntervalMin,
      retentionPercent: retentionPercent ?? this.retentionPercent,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
        'wrong_interval_min': wrongIntervalMin,
        'hard_floor_min': hardFloorMin,
        'hard_multiplier': hardMultiplier,
        'medium_first_min': mediumFirstMin,
        'medium_multiplier': mediumMultiplier,
        'easy_first_min': easyFirstMin,
        'easy_multiplier': easyMultiplier,
        'max_interval_min': maxIntervalMin,
        'retention_percent': retentionPercent,
        'cooldown_seconds': cooldownSeconds,
      };

  factory ReviewSettings.fromJson(Map<String, dynamic> json) {
    const d = ReviewSettings();
    return ReviewSettings(
      wrongIntervalMin:
          (json['wrong_interval_min'] as num?)?.toDouble() ?? d.wrongIntervalMin,
      hardFloorMin: (json['hard_floor_min'] as num?)?.toDouble() ?? d.hardFloorMin,
      hardMultiplier:
          (json['hard_multiplier'] as num?)?.toDouble() ?? d.hardMultiplier,
      mediumFirstMin:
          (json['medium_first_min'] as num?)?.toDouble() ?? d.mediumFirstMin,
      mediumMultiplier:
          (json['medium_multiplier'] as num?)?.toDouble() ?? d.mediumMultiplier,
      easyFirstMin: (json['easy_first_min'] as num?)?.toDouble() ?? d.easyFirstMin,
      easyMultiplier:
          (json['easy_multiplier'] as num?)?.toDouble() ?? d.easyMultiplier,
      maxIntervalMin:
          (json['max_interval_min'] as num?)?.toDouble() ?? d.maxIntervalMin,
      retentionPercent:
          (json['retention_percent'] as num?)?.toDouble() ?? d.retentionPercent,
      cooldownSeconds:
          (json['cooldown_seconds'] as num?)?.toInt() ?? d.cooldownSeconds,
    );
  }
}
