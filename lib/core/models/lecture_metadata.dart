class VideoInfo {
  const VideoInfo({
    required this.id,
    required this.title,
    required this.order,
    required this.durationSeconds,
    required this.segmentCount,
  });

  final String id;
  final String title;
  final int order;
  final int durationSeconds;
  final int segmentCount;

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
        id: j['id'] as String,
        title: j['title'] as String,
        order: (j['order'] as num?)?.toInt() ?? 0,
        durationSeconds: (j['duration_seconds'] as num?)?.toInt() ?? 0,
        segmentCount: (j['segment_count'] as num?)?.toInt() ?? 0,
      );

  String get formattedDuration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}

class FileInfo {
  const FileInfo({
    required this.id,
    required this.title,
    required this.filename,
    this.mimeType = 'application/octet-stream',
    this.videoIds = const [],
    this.sizeBytes = 0,
  });

  final String id;
  final String title;
  final String filename;
  final String mimeType;
  final List<String> videoIds; // empty = linked to all videos in the lecture
  final int sizeBytes;

  factory FileInfo.fromJson(Map<String, dynamic> j) => FileInfo(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        filename: j['filename'] as String,
        mimeType: j['mime_type'] as String? ??
            j['type'] as String? ?? 'application/octet-stream',
        videoIds: j['video_ids'] != null
            ? List<String>.from(j['video_ids'] as List)
            : [],
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
      );

  bool appliesToVideo(String vid) => videoIds.isEmpty || videoIds.contains(vid);
}

class LectureMetadata {
  const LectureMetadata({
    required this.lectureId,
    required this.courseId,
    required this.title,
    required this.teacherUid,
    required this.createdAt,
    required this.videos,
    required this.files,
    required this.totalDurationSeconds,
  });

  final String lectureId;
  final String courseId;
  final String title;
  final String teacherUid;
  final DateTime createdAt;
  final List<VideoInfo> videos;
  final List<FileInfo> files;
  final int totalDurationSeconds;

  factory LectureMetadata.fromJson(Map<String, dynamic> j) => LectureMetadata(
        lectureId: j['lecture_id'] as String,
        courseId: j['course_id'] as String,
        title: j['title'] as String,
        teacherUid: j['teacher_uid'] as String? ?? '',
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ??
            DateTime.now(),
        videos: (j['videos'] as List? ?? [])
            .map((v) => VideoInfo.fromJson(v as Map<String, dynamic>))
            .toList(),
        files: (j['files'] as List? ?? [])
            .map((f) => FileInfo.fromJson(f as Map<String, dynamic>))
            .toList(),
        totalDurationSeconds:
            (j['total_duration_seconds'] as num?)?.toInt() ?? 0,
      );

  String get formattedDuration {
    final h = totalDurationSeconds ~/ 3600;
    final m = (totalDurationSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}
