class AnnouncementModel {
  final String id;
  final String title;
  final String body;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? expiresAt;
  // Scopes this announcement to one lecture's card instead of the global
  // feed — null for ordinary teacher announcements. Set by the "Publish
  // Update" flow (upsert_lecture_announcement in firebase_uploader.py) to
  // notify students a lecture has an update available, and what it contains.
  final String? lectureId;

  const AnnouncementModel({
    required this.id,
    required this.title,
    required this.body,
    required this.isActive,
    required this.createdAt,
    this.expiresAt,
    this.lectureId,
  });

  /// [data] comes from FirestoreRest, which already decodes Firestore's wire
  /// format into plain Dart types — timestamp fields arrive as [DateTime]
  /// directly, not a [Timestamp] wrapper.
  factory AnnouncementModel.fromMap(String id, Map<String, dynamic> data) {
    return AnnouncementModel(
      id: id,
      title: data['title'] as String? ?? '',
      body: data['body'] as String? ?? '',
      isActive: data['is_active'] as bool? ?? false,
      createdAt: data['created_at'] as DateTime? ?? DateTime.now(),
      expiresAt: data['expires_at'] as DateTime?,
      lectureId: data['lecture_id'] as String?,
    );
  }
}
