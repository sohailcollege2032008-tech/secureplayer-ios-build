/// How quiz questions are laid out on screen.
enum QuizLayoutMode { perPage, scrollAll }

/// Student-facing quiz-taking preferences. Global (not per-course/per-quiz),
/// persisted via SharedPreferences — see quiz_settings_service.dart.
class QuizSettings {
  const QuizSettings({
    this.shuffleQuestions = false,
    this.shuffleOptions = false,
    this.swipeNavigationEnabled = true,
    this.layoutMode = QuizLayoutMode.perPage,
    this.fontSize = 16.0,
    this.fontFamily,
  });

  final bool shuffleQuestions;
  final bool shuffleOptions;
  // Gates touch-swipe, trackpad-gesture, AND arrow-key navigation as one toggle.
  final bool swipeNavigationEnabled;
  final QuizLayoutMode layoutMode;
  final double fontSize;
  // null = system default. No custom fonts are bundled as assets yet, so the
  // settings UI only offers "Default" for now — this field exists so adding
  // real choices later is a UI-only change, not a plumbing change.
  final String? fontFamily;

  static const double minFontSize = 12.0;
  static const double maxFontSize = 24.0;

  QuizSettings copyWith({
    bool? shuffleQuestions,
    bool? shuffleOptions,
    bool? swipeNavigationEnabled,
    QuizLayoutMode? layoutMode,
    double? fontSize,
    String? fontFamily,
  }) {
    return QuizSettings(
      shuffleQuestions: shuffleQuestions ?? this.shuffleQuestions,
      shuffleOptions: shuffleOptions ?? this.shuffleOptions,
      swipeNavigationEnabled:
          swipeNavigationEnabled ?? this.swipeNavigationEnabled,
      layoutMode: layoutMode ?? this.layoutMode,
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }

  Map<String, dynamic> toJson() => {
        'shuffle_questions': shuffleQuestions,
        'shuffle_options': shuffleOptions,
        'swipe_navigation_enabled': swipeNavigationEnabled,
        'layout_mode': layoutMode.name,
        'font_size': fontSize,
        if (fontFamily != null) 'font_family': fontFamily,
      };

  factory QuizSettings.fromJson(Map<String, dynamic> json) => QuizSettings(
        shuffleQuestions: json['shuffle_questions'] as bool? ?? false,
        shuffleOptions: json['shuffle_options'] as bool? ?? false,
        swipeNavigationEnabled:
            json['swipe_navigation_enabled'] as bool? ?? true,
        layoutMode: QuizLayoutMode.values.firstWhere(
          (m) => m.name == json['layout_mode'],
          orElse: () => QuizLayoutMode.perPage,
        ),
        fontSize: (json['font_size'] as num?)?.toDouble() ?? 16.0,
        fontFamily: json['font_family'] as String?,
      );
}
