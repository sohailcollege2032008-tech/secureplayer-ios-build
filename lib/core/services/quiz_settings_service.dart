import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/quiz_settings.dart';

/// Loads/saves the student's global quiz-taking preferences.
class QuizSettingsService {
  QuizSettingsService._();
  static final QuizSettingsService instance = QuizSettingsService._();

  static const _prefsKey = 'quiz_settings_v1';

  Future<QuizSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const QuizSettings();
    try {
      return QuizSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const QuizSettings();
    }
  }

  Future<void> save(QuizSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(settings.toJson()));
  }
}
