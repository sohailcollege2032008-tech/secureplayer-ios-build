import 'package:flutter/material.dart';

import '../../core/models/quiz_settings.dart';

/// Named text-style bundle for quiz rendering, scaled by the user's chosen
/// base font size. Preserves the pre-existing relative size hierarchy
/// (question largest, then options, then feedback/explanation) as ratios of
/// the base size rather than making every role the same size.
///
/// Colors that vary by state (correct/incorrect/selected option, feedback
/// title) are intentionally left unset here — callers apply those via
/// `.copyWith(color: ...)` on top of these base styles.
class QuizTextStyles {
  const QuizTextStyles({
    required this.questionStyle,
    required this.optionStyle,
    required this.explanationStyle,
    required this.feedbackTitleStyle,
  });

  final TextStyle questionStyle;
  final TextStyle optionStyle;
  final TextStyle explanationStyle;
  final TextStyle feedbackTitleStyle;

  factory QuizTextStyles.forSettings(QuizSettings settings) {
    final scale = settings.fontSize / 16.0;
    final family = settings.fontFamily;
    return QuizTextStyles(
      questionStyle: TextStyle(
        fontSize: 16 * scale,
        height: 1.5,
        fontWeight: FontWeight.w500,
        fontFamily: family,
        color: Colors.white,
      ),
      optionStyle: TextStyle(
        fontSize: 14.5 * scale,
        height: 1.4,
        fontFamily: family,
      ),
      explanationStyle: TextStyle(
        fontSize: 13.5 * scale,
        height: 1.4,
        fontFamily: family,
        color: Colors.white.withValues(alpha: 0.7),
      ),
      feedbackTitleStyle: TextStyle(
        fontSize: 14 * scale,
        fontWeight: FontWeight.bold,
        fontFamily: family,
      ),
    );
  }
}
