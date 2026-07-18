import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/review_settings.dart';

/// Loads/saves the student's global review (spaced-repetition) preferences.
class ReviewSettingsService {
  ReviewSettingsService._();
  static final ReviewSettingsService instance = ReviewSettingsService._();

  static const _prefsKey = 'review_settings_v1';

  Future<ReviewSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const ReviewSettings();
    try {
      return ReviewSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ReviewSettings();
    }
  }

  Future<void> save(ReviewSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(settings.toJson()));
  }
}
