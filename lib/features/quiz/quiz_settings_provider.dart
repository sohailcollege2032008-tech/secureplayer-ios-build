import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/quiz_settings.dart';
import '../../core/services/quiz_settings_service.dart';

class QuizSettingsNotifier extends StateNotifier<QuizSettings> {
  QuizSettingsNotifier() : super(const QuizSettings()) {
    _load();
  }

  Future<void> _load() async {
    state = await QuizSettingsService.instance.load();
  }

  /// Overwrites state with an already-loaded value — used once, in main(),
  /// to seed the provider from SharedPreferences before runApp() so no
  /// widget can ever read this notifier's constructor-time default. state
  /// is @protected on StateNotifier, so external code (main.dart) can't
  /// assign it directly; this method is the sanctioned way in.
  void seedFrom(QuizSettings settings) {
    state = settings;
  }

  Future<void> _update(QuizSettings next) async {
    state = next;
    await QuizSettingsService.instance.save(next);
  }

  Future<void> setShuffleQuestions(bool value) =>
      _update(state.copyWith(shuffleQuestions: value));

  Future<void> setShuffleOptions(bool value) =>
      _update(state.copyWith(shuffleOptions: value));

  Future<void> setSwipeNavigationEnabled(bool value) =>
      _update(state.copyWith(swipeNavigationEnabled: value));

  Future<void> setLayoutMode(QuizLayoutMode mode) =>
      _update(state.copyWith(layoutMode: mode));

  Future<void> setFontSize(double size) => _update(state.copyWith(
        fontSize: size.clamp(
            QuizSettings.minFontSize, QuizSettings.maxFontSize),
      ));
}

final quizSettingsProvider =
    StateNotifierProvider<QuizSettingsNotifier, QuizSettings>(
  (ref) => QuizSettingsNotifier(),
);
