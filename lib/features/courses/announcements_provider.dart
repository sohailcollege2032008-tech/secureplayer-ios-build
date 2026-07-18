import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/announcement_model.dart';
import '../../core/services/firestore_rest.dart';

// Single one-shot fetch of every active, unexpired announcement (global and
// lecture-scoped alike). Previously this was a 30s poll that never disposed
// (StreamProvider, not autoDispose) — it kept querying Firestore for the
// entire app process lifetime regardless of which screen was on top, and a
// second poll fanned out per lecture card on top of that. At student-app
// scale that's a real, unbounded, per-student-per-second cost for a banner
// that doesn't need sub-minute freshness. Both providers below now derive
// from this single fetch instead of running their own network timer;
// freshness comes from screen remount + the existing pull-to-refresh
// (see course_list_screen.dart / course_lectures_screen.dart RefreshIndicator).
final activeAnnouncementsProvider =
    FutureProvider.autoDispose<List<AnnouncementModel>>((ref) async {
  final docs = await FirestoreRest.instance.queryAnd(
    'announcements',
    [(field: 'is_active', op: 'EQUAL', value: true)],
    orderByField: 'created_at',
    descending: true,
  );
  final now = DateTime.now();
  return docs
      .map((r) => AnnouncementModel.fromMap(r.id, r.data))
      .where((a) => a.expiresAt == null || a.expiresAt!.isAfter(now))
      .toList();
});

/// Global banner feed shown above the courses list — excludes lecture-scoped
/// update notices, which render on their own lecture's card instead (see
/// [lectureAnnouncementsProvider]). Derived, not fetched — no extra reads.
final announcementsProvider =
    Provider.autoDispose<AsyncValue<List<AnnouncementModel>>>((ref) {
  return ref
      .watch(activeAnnouncementsProvider)
      .whenData((list) => list.where((a) => a.lectureId == null).toList());
});

/// Update notices scoped to one lecture — filtered client-side from
/// [activeAnnouncementsProvider]'s single fetch. No per-card network call.
final lectureAnnouncementsProvider = Provider.autoDispose
    .family<AsyncValue<List<AnnouncementModel>>, String>((ref, lectureId) {
  return ref
      .watch(activeAnnouncementsProvider)
      .whenData((list) => list.where((a) => a.lectureId == lectureId).toList());
});
