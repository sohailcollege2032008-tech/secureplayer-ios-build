import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/course_metadata.dart';
import '../../security_layer/secure_storage/secure_storage_provider.dart';
import 'sec_importer.dart';

final secImporterProvider = Provider<SecImporter>((ref) {
  return SecImporter(ref.read(secureStorageProvider));
});

/// Lists all locally imported courses by reading course sandbox directories.
/// For v2/v2.1 lectures, expands to one CourseMetadata entry per video so the
/// existing course-list grouping and detail screen work without restructuring.
final localCoursesProvider = FutureProvider<List<CourseMetadata>>((ref) async {
  final appDir = await getApplicationSupportDirectory();
  final coursesDir = Directory('${appDir.path}/courses');
  if (!await coursesDir.exists()) return [];

  final List<CourseMetadata> courses = [];
  await for (final entity in coursesDir.list()) {
    if (entity is! Directory) continue;
    final metadataFile = File('${entity.path}/metadata.json');
    if (!await metadataFile.exists()) continue;
    try {
      final json =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;

      // General Quiz collections (.secquiz) share format_version "1.0" with
      // legacy v1 lectures but are a different package_type — CourseMetadata
      // has no shape for them (its v1 branch would wrongly bind courseId to
      // the collection's PARENT course id instead of its own directory key).
      // They surface separately via generalQuizCollectionsProvider instead
      // (see review_providers.dart's reviewScopeOverviewProvider for where
      // that matters).
      if (json['package_type'] == 'quiz_collection') continue;

      final version = json['format_version'] as String? ?? '1.0';

      if (version == '2.0' || version == '2.1') {
        // Multi-video lecture — one CourseMetadata per video
        final lectureId = json['lecture_id'] as String;
        final parentCourseId = json['course_id'] as String? ?? '';
        final lectureTitle = json['title'] as String? ?? '';
        final teacherUid = json['teacher_uid'] as String? ?? '';
        final createdAt =
            DateTime.tryParse(json['created_at'] as String? ?? '') ??
                DateTime.now();
        final totalDuration =
            (json['total_duration_seconds'] as num?)?.toInt() ?? 0;
        final files = (json['files'] as List? ?? [])
            .map((f) => LectureFile.fromJson(f as Map<String, dynamic>))
            .toList();
        final fileIvMap = json['file_iv_map'] != null
            ? Map<String, String>.from(json['file_iv_map'] as Map)
            : <String, String>{};
        final watermarkConfig = json['watermark_config'] != null
            ? WatermarkConfig.fromJson(
                json['watermark_config'] as Map<String, dynamic>)
            : WatermarkConfig.off;
        final videos = json['videos'] as List? ?? [];
        for (final v in videos) {
          final vm = v as Map<String, dynamic>;
          courses.add(CourseMetadata(
            formatVersion: version,
            courseId: lectureId,
            videoId: vm['id'] as String,
            title: vm['title'] as String? ?? lectureTitle,
            lectureTitle: lectureTitle,
            teacherUid: teacherUid,
            createdAt: createdAt,
            segmentCount: (vm['segment_count'] as num?)?.toInt() ?? 0,
            ivMap: const {},
            quizIds: const [],
            durationSeconds:
                (vm['duration_seconds'] as num?)?.toInt() ?? totalDuration,
            checksum: '',
            files: files,
            fileIvMap: fileIvMap,
            watermarkConfig: watermarkConfig,
            videoWidth: (vm['width'] as num?)?.toInt() ?? 0,
            videoHeight: (vm['height'] as num?)?.toInt() ?? 0,
            parentCourseId: parentCourseId,
          ));
        }
        // File-only lecture: no videos but has files
        if (videos.isEmpty && files.isNotEmpty) {
          courses.add(CourseMetadata(
            formatVersion: version,
            courseId: lectureId,
            videoId: '',
            title: lectureTitle,
            lectureTitle: lectureTitle,
            teacherUid: teacherUid,
            createdAt: createdAt,
            segmentCount: 0,
            ivMap: const {},
            quizIds: const [],
            durationSeconds: 0,
            checksum: '',
            files: files,
            fileIvMap: fileIvMap,
            watermarkConfig: watermarkConfig,
            parentCourseId: parentCourseId,
          ));
        }
      } else {
        courses.add(CourseMetadata.fromJson(json));
      }
    } catch (_) {
      continue;
    }
  }

  courses.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return courses;
});
