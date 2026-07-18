enum WatermarkMode { tiled, boldGhost }

enum WatermarkApplyTo { both, videos, files }

class WatermarkConfig {
  const WatermarkConfig({
    this.enabled = false,
    this.showName = true,
    this.showEmail = false,
    this.showPhone = true,
    this.opacity = 0.15,
    this.fontSize = 14.0,
    this.mode = WatermarkMode.boldGhost,
    this.applyTo = WatermarkApplyTo.both,
  });

  final bool enabled;
  final bool showName;
  final bool showEmail;
  final bool showPhone;
  final double opacity;
  final double fontSize;
  final WatermarkMode mode;
  final WatermarkApplyTo applyTo;

  bool get applyToVideos =>
      enabled &&
      (applyTo == WatermarkApplyTo.both || applyTo == WatermarkApplyTo.videos);
  bool get applyToFiles =>
      enabled &&
      (applyTo == WatermarkApplyTo.both || applyTo == WatermarkApplyTo.files);

  static const WatermarkConfig off = WatermarkConfig();

  factory WatermarkConfig.fromJson(Map<String, dynamic> json) {
    final applyToStr = json['apply_to'] as String? ?? 'both';
    final applyTo = applyToStr == 'videos'
        ? WatermarkApplyTo.videos
        : (applyToStr == 'files'
            ? WatermarkApplyTo.files
            : WatermarkApplyTo.both);

    return WatermarkConfig(
      enabled: json['enabled'] as bool? ?? false,
      showName: json['show_name'] as bool? ?? true,
      showEmail: json['show_email'] as bool? ?? false,
      showPhone: json['show_phone'] as bool? ?? true,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 0.15,
      fontSize: (json['font_size'] as num?)?.toDouble() ?? 14.0,
      mode: json['mode'] == 'bold_ghost'
          ? WatermarkMode.boldGhost
          : WatermarkMode.tiled,
      applyTo: applyTo,
    );
  }
}

class LectureFile {
  const LectureFile({
    required this.id,
    required this.title,
    required this.filename,
    required this.mimeType,
    required this.videoIds,
    required this.sizeBytes,
  });

  final String id;
  final String title;
  final String filename;
  final String mimeType;
  final List<String> videoIds; // empty = linked to all videos
  final int sizeBytes;

  factory LectureFile.fromJson(Map<String, dynamic> json) => LectureFile(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        filename: json['filename'] as String? ?? '',
        mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
        videoIds: json['video_ids'] != null
            ? List<String>.from(json['video_ids'] as List)
            : [],
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      );

  bool appliesToVideo(String vid) => videoIds.isEmpty || videoIds.contains(vid);
}

class CourseMetadata {
  const CourseMetadata({
    required this.formatVersion,
    required this.courseId,
    required this.videoId,
    required this.title,
    required this.teacherUid,
    required this.createdAt,
    required this.segmentCount,
    required this.ivMap,
    required this.quizIds,
    required this.durationSeconds,
    required this.checksum,
    this.files = const [],
    this.lectureTitle = '',
    this.fileIvMap = const {},
    this.watermarkConfig = WatermarkConfig.off,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.parentCourseId = '',
  });

  final String formatVersion;
  final String courseId;
  final String videoId;
  final String title; // video-level title for v2; course title for v1
  final String
      lectureTitle; // lecture-level title for v2 (shown in course list card)
  final String teacherUid;
  final DateTime createdAt;
  final int segmentCount;
  final Map<String, String> ivMap;
  final List<String> quizIds;
  final int durationSeconds;
  final String checksum;
  final List<LectureFile> files;
  final Map<String, String> fileIvMap; // fileId -> ivHex for encrypted files
  final WatermarkConfig watermarkConfig;
  // Real pixel dimensions from ffprobe at encryption time (v2.1+ only; 0 for
  // legacy .sec files). Lets the player size itself correctly from the very
  // first frame instead of waiting on runtime aspect-ratio auto-detection.
  final int videoWidth;
  final int videoHeight;
  // Parent course this lecture belongs to (metadata.json `course_id`, v2+).
  // Used to group lectures by course in the review scope picker. Empty for
  // lectures predating the field; v1 units are their own course.
  final String parentCourseId;

  bool get isFileOnly => segmentCount == 0 && videoId.isEmpty;

  double? get aspectRatio =>
      (videoWidth > 0 && videoHeight > 0) ? videoWidth / videoHeight : null;

  /// For the course list card: shows lecture title if available, else video title.
  String get displayTitle => lectureTitle.isNotEmpty ? lectureTitle : title;

  factory CourseMetadata.fromJson(Map<String, dynamic> json) {
    final version = json['format_version'] as String? ?? '1.0';

    final fileIvMap = json['file_iv_map'] != null
        ? Map<String, String>.from(json['file_iv_map'] as Map)
        : <String, String>{};
    final watermarkConfig = json['watermark_config'] != null
        ? WatermarkConfig.fromJson(
            json['watermark_config'] as Map<String, dynamic>)
        : WatermarkConfig.off;

    // v2 / v2.1 format — lecture-level .sec with multiple videos
    if (version == '2.0' || version == '2.1') {
      final videos = json['videos'] as List? ?? [];
      final firstVideo = videos.isNotEmpty
          ? videos.first as Map<String, dynamic>
          : <String, dynamic>{};
      final files = (json['files'] as List? ?? [])
          .map((f) => LectureFile.fromJson(f as Map<String, dynamic>))
          .toList();
      return CourseMetadata(
        formatVersion: version,
        courseId: json['lecture_id'] as String, // lectureId acts as key
        videoId: firstVideo['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        teacherUid: json['teacher_uid'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
        segmentCount: (firstVideo['segment_count'] as num?)?.toInt() ?? 0,
        ivMap: {}, // v2+ has no global iv_map — IVs are in per-video playlists
        quizIds: [],
        durationSeconds: (json['total_duration_seconds'] as num?)?.toInt() ?? 0,
        checksum: '',
        files: files,
        fileIvMap: fileIvMap,
        watermarkConfig: watermarkConfig,
        videoWidth: (firstVideo['width'] as num?)?.toInt() ?? 0,
        videoHeight: (firstVideo['height'] as num?)?.toInt() ?? 0,
        parentCourseId: json['course_id'] as String? ?? '',
      );
    }

    // v1 format
    return CourseMetadata(
      formatVersion: version,
      courseId: json['course_id'] as String,
      videoId: json['video_id'] as String? ?? '',
      title: json['title'] as String,
      teacherUid: json['teacher_uid'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      segmentCount: (json['segment_count'] as num?)?.toInt() ?? 0,
      ivMap: json['iv_map'] != null
          ? Map<String, String>.from(json['iv_map'] as Map)
          : {},
      quizIds: json['quiz_ids'] != null
          ? List<String>.from(json['quiz_ids'] as List)
          : [],
      durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
      checksum: json['checksum'] as String? ?? '',
      fileIvMap: fileIvMap,
      watermarkConfig: watermarkConfig,
      // A v1 unit IS its own course — same id for both.
      parentCourseId: json['course_id'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'format_version': formatVersion,
        'course_id': courseId,
        'video_id': videoId,
        'title': title,
        'teacher_uid': teacherUid,
        'created_at': createdAt.toIso8601String(),
        'segment_count': segmentCount,
        'iv_map': ivMap,
        'quiz_ids': quizIds,
        'duration_seconds': durationSeconds,
        'checksum': checksum,
      };

  String get compoundId =>
      videoId.isNotEmpty ? '${courseId}_$videoId' : courseId;

  String get formattedDuration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}
