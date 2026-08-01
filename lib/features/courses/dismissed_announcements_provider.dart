import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kDismissedKey = 'dismissed_announcement_ids';

/// Remembers which announcement/update-notice banners the student dismissed
/// with the X, so they never reappear (persisted per device via
/// SharedPreferences). Announcement ids are Firestore doc ids — stable.
class DismissedAnnouncementsNotifier extends StateNotifier<Set<String>> {
  DismissedAnnouncementsNotifier() : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = (prefs.getStringList(_kDismissedKey) ?? const []).toSet();
    } catch (_) {
      state = const {};
    }
  }

  Future<void> dismiss(String id) async {
    if (state.contains(id)) return;
    state = {...state, id};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kDismissedKey, state.toList());
    } catch (_) {}
  }
}

final dismissedAnnouncementsProvider =
    StateNotifierProvider<DismissedAnnouncementsNotifier, Set<String>>(
  (ref) => DismissedAnnouncementsNotifier(),
);
