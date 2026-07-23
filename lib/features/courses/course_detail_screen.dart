import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/course_metadata.dart';
import '../../core/models/quiz.dart';
import '../../core/services/cloud_function_http_client.dart';
import '../../core/utils/device_id_util.dart';
import '../auth/auth_providers.dart';
import '../../local_server/decryption/iv_map_crypto.dart';
import '../../security_layer/secure_storage/secure_storage_provider.dart';
import '../../shared/widgets/app_drawer.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../quiz/quiz_history_service.dart';
import '../quiz/quiz_provider.dart';
import 'courses_provider.dart';
import '../../app/theme.dart';

// Provides EVERY normal quiz + last attempt for a specific video (keyed by
// lectureId:videoId) — not just the first — so a video with several attached
// quizzes shows a row for each, matching how multiple files render.
final _videoQuizBannerProvider = FutureProvider.family<
    List<({Quiz quiz, LocalQuizAttempt? lastAttempt})>,
    String>((ref, key) async {
  final parts = key.split(':');
  if (parts.length != 2) return const [];
  final lectureId = parts[0];
  final videoId = parts[1];

  final quizzes = await ref.watch(courseQuizzesProvider(lectureId).future);
  final matching = quizzes
      .where((q) => !q.isPopupQuiz && q.appliesToVideo(videoId))
      .toList();
  if (matching.isEmpty) return const [];

  final service = ref.read(quizHistoryServiceProvider);
  final result = <({Quiz quiz, LocalQuizAttempt? lastAttempt})>[];
  for (final quiz in matching) {
    final last = await service.getLatestAttempt(quiz.id);
    result.add((quiz: quiz, lastAttempt: last));
  }
  return result;
});

class CourseDetailScreen extends ConsumerStatefulWidget {
  const CourseDetailScreen({super.key, required this.courseId});

  final String courseId;

  @override
  ConsumerState<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends ConsumerState<CourseDetailScreen> {
  // Guards against a fast double-tap on a video card pushing the
  // VideoPlayerScreen route twice — both onTap handlers below call
  // _openVideo() with no debounce, and context.push() is synchronous/instant,
  // so two taps landing in the same frame (or during a laggy rebuild) used to
  // push two overlapping player instances onto the Navigator stack. Only the
  // TOP one gets popped by the back button, leaving the other alive
  // underneath — its player and shelf server keep running invisibly, exactly
  // matching the "video keeps playing in the background after I exit" bug.
  bool _isOpeningVideo = false;

  // Called when iv_map.enc is missing but segments are already on disk.
  // Fetches the key + ivMap from the Cloud Function and writes iv_map.enc
  // without re-extracting the .sec archive.
  Future<bool> _fixIncompleteImport(ScaffoldMessengerState messenger,
      CourseMetadata metadata, String courseDir) async {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Completing import, please wait...'),
        duration: Duration(seconds: 10),
      ),
    );
    try {
      final deviceId = await DeviceIdUtil.getDeviceId();
      final payload = {
        'lectureId': metadata.courseId,
        'courseId': metadata.courseId,
        'videoId': metadata.videoId,
        'deviceId': deviceId,
      };
      // cloud_functions has no Windows platform implementation at all — the
      // SDK call below used to throw MissingPluginException there, surfacing
      // as a raw error to the user. Route Windows through the same pinned
      // raw-HTTP path used for imports.
      final data = Platform.isWindows
          ? await callCloudFunctionViaHttp('getCourseKey', payload)
          : (await FirebaseFunctions.instanceFor(region: 'us-central1')
                  .httpsCallable('getCourseKey',
                      options: HttpsCallableOptions(
                          timeout: const Duration(seconds: 20)))
                  .call(payload))
              .data as Map<String, dynamic>;
      final keyHex = data['keyHex'] as String;
      final ivMap = Map<String, String>.from(data['ivMap'] as Map);

      await ref
          .read(secureStorageProvider)
          .storeKey(metadata.compoundId, keyHex);
      final encrypted = encryptIvMap(ivMap, keyHex);
      await File('$courseDir/iv_map.enc').writeAsBytes(encrypted);

      messenger.clearSnackBars();
      return true;
    } catch (e) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not complete import: $e'),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
  }

  // Wrapper so the fire-and-forget tap handler can never fail invisibly:
  // main.dart's global handler swallows uncaught async errors on Android
  // (Crashlytics-only), which turned any throw in here into a silent no-op.
  Future<void> _openVideo(BuildContext context, CourseMetadata metadata) async {
    if (_isOpeningVideo) return;
    _isOpeningVideo = true;
    // TEMP diagnostic probe — remove after the dead-Watch-button bug is fixed.
    debugPrint(
        'SP_TAP ${metadata.formatVersion} ${metadata.courseId}/${metadata.videoId}');
    try {
      await _openVideoInner(context, metadata);
    } catch (e, st) {
      debugPrint('SP_OPENVIDEO_ERROR: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      _isOpeningVideo = false;
    }
  }

  Future<void> _openVideoInner(
      BuildContext context, CourseMetadata metadata) async {
    // v2/v2.1 format: lectureId is stored in courseId, videoId in videoId field.
    // No ivMap needed — IVs are embedded in playlists and the player handles decryption.
    if (metadata.formatVersion == '2.0' || metadata.formatVersion == '2.1') {
      if (context.mounted) {
        await context.push(
          '/player/${metadata.courseId}/${metadata.videoId}',
          extra: {
            'title': metadata.title,
            'watermarkConfig': metadata.watermarkConfig,
            'aspectRatio': metadata.aspectRatio,
          },
        );
      }
      return;
    }

    // v1 legacy flow (iv_map.enc based)
    final messenger = ScaffoldMessenger.of(context);
    final appDir = await getApplicationSupportDirectory();
    final courseDir = '${appDir.path}/courses/${metadata.compoundId}';

    final ivMapFile = File('$courseDir/iv_map.enc');
    if (!await ivMapFile.exists()) {
      final fixed = await _fixIncompleteImport(messenger, metadata, courseDir);
      if (!fixed) return;
    }

    final keyHex =
        await ref.read(secureStorageProvider).getKey(metadata.compoundId);
    if (keyHex == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Decryption key missing. Try re-importing.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final Map<String, String> ivMap;
    try {
      final encrypted = await ivMapFile.readAsBytes();
      ivMap = decryptIvMap(encrypted, keyHex);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Video data corrupted. Try re-importing.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (context.mounted) {
      await context.push(
        '/player/${metadata.compoundId}/${metadata.videoId}',
        extra: {
          'title': metadata.title,
          'watermarkConfig': metadata.watermarkConfig,
        },
      );
    }
    // ignore: unused_local_variable
    final _ = ivMap; // v1 ivMap kept for reference — server now reads from disk
  }

  @override
  Widget build(BuildContext context) {
    final coursesAsync = ref.watch(localCoursesProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      drawer: const AppDrawer(),
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon:
              const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: coursesAsync.whenData((all) {
              final match = all.where((m) => m.courseId == widget.courseId);
              final lectureTitle =
                  match.isNotEmpty ? match.first.lectureTitle : '';
              return Text(
                lectureTitle.isNotEmpty ? lectureTitle : widget.courseId,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
                overflow: TextOverflow.ellipsis,
              );
            }).valueOrNull ??
            Text(
              widget.courseId,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
              overflow: TextOverflow.ellipsis,
            ),
      ),
      body: coursesAsync.when(
        loading: () => const Center(child: LoadingIndicator()),
        error: (e, _) => Center(
          child:
              Text(e.toString(), style: const TextStyle(color: Colors.white70)),
        ),
        data: (all) {
          final videos =
              all.where((m) => m.courseId == widget.courseId).toList();
          if (videos.isEmpty) {
            return const Center(
              child: Text('No content imported for this course.',
                  style: TextStyle(color: Colors.white54)),
            );
          }

          final first = videos.first;
          final allFiles = first.files;
          final fileIvMap = first.fileIvMap;
          final watermarkConfig = first.watermarkConfig;

          // File-only course: skip video list, show files only
          if (first.isFileOnly) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Row(
                  children: [
                    Icon(Icons.folder_open_rounded,
                        color: AppTheme.primary, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Files & Materials',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ...allFiles.map((f) => _FileCard(
                      file: f,
                      lectureId: widget.courseId,
                      fileIvMap: fileIvMap,
                      watermarkConfig: watermarkConfig,
                    )),
              ],
            );
          }

          final lectureQuizzesAsync =
              ref.watch(courseQuizzesProvider(widget.courseId));
          final lectureFiles =
              allFiles.where((f) => f.videoIds.isEmpty).toList();

          // Pre-compute O(M) index so itemBuilder lookup is O(1) per item.
          final videoFilesMap = <String, List<LectureFile>>{};
          for (final f in allFiles) {
            for (final vid in f.videoIds) {
              videoFilesMap.putIfAbsent(vid, () => []).add(f);
            }
          }

          final allQuizzes = lectureQuizzesAsync.valueOrNull ?? const <Quiz>[];
          final renderItems = _buildVideoRenderItems(
            context,
            videos,
            allQuizzes,
            videoFilesMap,
            fileIvMap,
            watermarkConfig,
          );

          return Column(
            children: [
              lectureQuizzesAsync.when(
                data: (quizzes) {
                  final lectureQuizzes =
                      quizzes.where((q) => q.isLectureLevel).toList();
                  if (lectureQuizzes.isEmpty) return const SizedBox.shrink();
                  return Column(
                    children: lectureQuizzes
                        .map((q) => _buildFinalExamBanner(q))
                        .toList(),
                  );
                },
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
              if (lectureFiles.isNotEmpty)
                _buildLectureFilesSection(
                    lectureFiles, fileIvMap, watermarkConfig),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: renderItems,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // Groups videos that share a multi-video normal quiz under one bordered
  // container (quiz shown once, after the last video in that group's span)
  // instead of duplicating the quiz banner under every video it applies to.
  // Videos not covered by any multi-video quiz render as before (_VideoGroup).
  List<Widget> _buildVideoRenderItems(
    BuildContext context,
    List<CourseMetadata> videos,
    List<Quiz> allQuizzes,
    Map<String, List<LectureFile>> videoFilesMap,
    Map<String, String> fileIvMap,
    WatermarkConfig watermarkConfig,
  ) {
    final multiVideoQuizzes = allQuizzes
        .where(
            (q) => !q.isPopupQuiz && !q.isLectureLevel && q.videoIds.length > 1)
        .toList();

    final idToIndex = <String, int>{
      for (var i = 0; i < videos.length; i++) videos[i].videoId: i,
    };

    // videoIndex -> the span [start,end] + quiz it belongs to, if any.
    final spanForIndex = <int, ({int start, int end, Quiz quiz})>{};
    for (final quiz in multiVideoQuizzes) {
      final indices =
          quiz.videoIds.map((id) => idToIndex[id]).whereType<int>().toList();
      if (indices.length < 2) continue; // videos not found locally
      final start = indices.reduce((a, b) => a < b ? a : b);
      final end = indices.reduce((a, b) => a > b ? a : b);
      for (var i = start; i <= end; i++) {
        spanForIndex[i] = (start: start, end: end, quiz: quiz);
      }
    }

    final items = <Widget>[];
    var i = 0;
    while (i < videos.length) {
      final span = spanForIndex[i];
      if (span != null && span.start == i) {
        final groupVideos = [
          for (var j = span.start; j <= span.end; j++) videos[j],
        ];
        items.add(_MultiVideoQuizGroupCard(
          // Stable identity independent of courseQuizzesProvider's
          // loading-to-data transition: before it resolves, these videos
          // render as standalone _VideoGroup items; once the multi-video
          // quiz data arrives, they merge into this card instead. That's a
          // genuine widget-type change Flutter must rebuild regardless of
          // keys, but keying by span start still protects every OTHER item
          // in the list from being needlessly torn down by the shift.
          key: ValueKey('quiz_group_${groupVideos.first.videoId}'),
          videos: groupVideos,
          quiz: span.quiz,
          lectureId: widget.courseId,
          fileIvMap: fileIvMap,
          watermarkConfig: watermarkConfig,
          videoFilesMap: videoFilesMap,
          onOpenVideo: (m) => _openVideo(context, m),
        ));
        i = span.end + 1;
      } else {
        final video = videos[i];
        items.add(_VideoGroup(
          key: ValueKey('video_group_${video.videoId}'),
          metadata: video,
          onTap: () => _openVideo(context, video),
          files: videoFilesMap[video.videoId] ?? [],
          lectureId: widget.courseId,
          fileIvMap: fileIvMap,
          watermarkConfig: watermarkConfig,
        ));
        i++;
      }
    }
    return items;
  }

  Widget _buildLectureFilesSection(
    List<LectureFile> files,
    Map<String, String> fileIvMap,
    WatermarkConfig watermarkConfig,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.attach_file_rounded, color: Colors.white38, size: 15),
              SizedBox(width: 6),
              Text(
                'Lecture Files',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...files.map((f) => _FileCard(
                file: f,
                lectureId: widget.courseId,
                fileIvMap: fileIvMap,
                watermarkConfig: watermarkConfig,
              )),
        ],
      ),
    );
  }

  Widget _buildFinalExamBanner(Quiz quiz) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => context.push(
            '/quiz/${widget.courseId}/${quiz.id}',
            extra: {'quiz': quiz},
          ),
          icon: const Icon(Icons.school_rounded, size: 20),
          label: Text(
            quiz.title.isNotEmpty ? quiz.title : 'Final Exam',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
        ),
      ),
    );
  }
}

// Thin wrapper: adds the standalone card's border/margin around
// _VideoGroupContent. Used for videos not part of any multi-video quiz
// group — those instead render inside _MultiVideoQuizGroupCard, which
// supplies its own outer border spanning the whole group.
class _VideoGroup extends StatelessWidget {
  const _VideoGroup({
    super.key,
    required this.metadata,
    required this.onTap,
    required this.files,
    required this.lectureId,
    required this.fileIvMap,
    required this.watermarkConfig,
  });

  final CourseMetadata metadata;
  final VoidCallback onTap;
  final List<LectureFile> files;
  final String lectureId;
  final Map<String, String> fileIvMap;
  final WatermarkConfig watermarkConfig;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: _VideoGroupContent(
        metadata: metadata,
        onTap: onTap,
        files: files,
        lectureId: lectureId,
        fileIvMap: fileIvMap,
        watermarkConfig: watermarkConfig,
      ),
    );
  }
}

// Video row + attached files + single-video-scoped quiz banners. No outer
// decoration of its own — reusable standalone (wrapped by _VideoGroup) or
// stacked inside _MultiVideoQuizGroupCard's shared border.
class _VideoGroupContent extends ConsumerWidget {
  const _VideoGroupContent({
    required this.metadata,
    required this.onTap,
    required this.files,
    required this.lectureId,
    required this.fileIvMap,
    required this.watermarkConfig,
  });

  final CourseMetadata metadata;
  final VoidCallback onTap;
  final List<LectureFile> files;
  final String lectureId;
  final Map<String, String> fileIvMap;
  final WatermarkConfig watermarkConfig;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bannerAsync =
        ref.watch(_videoQuizBannerProvider('$lectureId:${metadata.videoId}'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // — Video row —
        GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.play_circle_outline_rounded,
                      color: AppTheme.primary, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        metadata.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.access_time_rounded,
                              color: Colors.white38, size: 13),
                          const SizedBox(width: 4),
                          Text(
                            metadata.formattedDuration,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                          if (metadata.videoId.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            const Icon(Icons.label_outline_rounded,
                                color: Colors.white24, size: 13),
                            const SizedBox(width: 4),
                            Text(
                              metadata.videoId,
                              style: const TextStyle(
                                  color: Colors.white24, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Watch pill button
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Watch',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // — Attached files + single-video quizzes in a single inset
        // container (3-D depth effect). Multi-video quizzes are excluded
        // here — they render once at the bottom of
        // _MultiVideoQuizGroupCard instead of duplicated under each video.
        Builder(builder: (context) {
          final banners = (bannerAsync.valueOrNull ?? const [])
              .where((b) => b.quiz.videoIds.length <= 1)
              .toList();
          if (files.isEmpty && banners.isEmpty) return const SizedBox.shrink();
          return Container(
            margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF10101E),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...files.map((f) => _AttachedFileRow(
                      file: f,
                      lectureId: lectureId,
                      fileIvMap: fileIvMap,
                      watermarkConfig: watermarkConfig,
                    )),
                ...banners.map((b) => _AttachedQuizRow(
                      quiz: b.quiz,
                      last: b.lastAttempt,
                      lectureId: lectureId,
                      videoId: metadata.videoId,
                    )),
              ],
            ),
          );
        }),
      ],
    );
  }
}

// One outer bordered container spanning every video a multi-video quiz
// applies to (in order), with the shared quiz shown once at the bottom
// after the last video — instead of the quiz banner duplicating under
// each individual video.
class _MultiVideoQuizGroupCard extends ConsumerWidget {
  const _MultiVideoQuizGroupCard({
    super.key,
    required this.videos,
    required this.quiz,
    required this.lectureId,
    required this.fileIvMap,
    required this.watermarkConfig,
    required this.videoFilesMap,
    required this.onOpenVideo,
  });

  final List<CourseMetadata> videos; // ordered, contiguous span
  final Quiz quiz;
  final String lectureId;
  final Map<String, String> fileIvMap;
  final WatermarkConfig watermarkConfig;
  final Map<String, List<LectureFile>> videoFilesMap;
  final void Function(CourseMetadata) onOpenVideo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastVideoId = videos.last.videoId;
    final bannerAsync =
        ref.watch(_videoQuizBannerProvider('$lectureId:$lastVideoId'));
    final matchingBanners =
        bannerAsync.valueOrNull?.where((b) => b.quiz.id == quiz.id) ?? const [];
    final lastAttempt =
        matchingBanners.isNotEmpty ? matchingBanners.first.lastAttempt : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.3),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var idx = 0; idx < videos.length; idx++)
            DecoratedBox(
              decoration: idx > 0
                  ? const BoxDecoration(
                      border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
                    )
                  : const BoxDecoration(),
              child: _VideoGroupContent(
                metadata: videos[idx],
                onTap: () => onOpenVideo(videos[idx]),
                files: videoFilesMap[videos[idx].videoId] ?? [],
                lectureId: lectureId,
                fileIvMap: fileIvMap,
                watermarkConfig: watermarkConfig,
              ),
            ),
          _AttachedQuizRow(
            quiz: quiz,
            last: lastAttempt,
            lectureId: lectureId,
            videoId: lastVideoId,
          ),
        ],
      ),
    );
  }
}

class _FileCard extends ConsumerWidget {
  const _FileCard({
    required this.file,
    required this.lectureId,
    required this.fileIvMap,
    required this.watermarkConfig,
  });

  final LectureFile file;
  final String lectureId;
  final Map<String, String> fileIvMap;
  final WatermarkConfig watermarkConfig;

  IconData _iconFor(String mime) {
    if (mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (mime.startsWith('image/')) return Icons.image_rounded;
    if (mime.contains('word') || mime.contains('document')) {
      return Icons.description_rounded;
    }
    if (mime.contains('presentation') || mime.contains('powerpoint')) {
      return Icons.slideshow_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  String _sizeLabel() {
    if (file.sizeBytes <= 0) return '';
    if (file.sizeBytes < 1024 * 1024) {
      return '${(file.sizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(file.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(studentProfileProvider).valueOrNull;
    return GestureDetector(
      onTap: () => context.push(
        '/file/$lectureId/${file.id}',
        extra: {
          'filename': file.filename,
          'title': file.title,
          'mimeType': file.mimeType,
          'fileIvMap': fileIvMap,
          'watermarkConfig': watermarkConfig,
          'studentName': profile?.name ?? '',
          'studentEmail': profile?.email ?? '',
          'studentPhone': profile?.phone ?? '',
        },
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            Icon(_iconFor(file.mimeType), color: Colors.amber, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.title.isNotEmpty ? file.title : file.filename,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_sizeLabel().isNotEmpty)
                    Text(
                      _sizeLabel(),
                      style:
                          const TextStyle(color: Colors.white24, fontSize: 11),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white24, size: 16),
          ],
        ),
      ),
    );
  }
}

// Attached file row — sits inside a _VideoGroup container, no outer border.
class _AttachedFileRow extends ConsumerWidget {
  const _AttachedFileRow({
    required this.file,
    required this.lectureId,
    required this.fileIvMap,
    required this.watermarkConfig,
  });

  final LectureFile file;
  final String lectureId;
  final Map<String, String> fileIvMap;
  final WatermarkConfig watermarkConfig;

  IconData _iconFor(String mime) {
    if (mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (mime.startsWith('image/')) return Icons.image_rounded;
    if (mime.contains('word') || mime.contains('document')) {
      return Icons.description_rounded;
    }
    if (mime.contains('presentation') || mime.contains('powerpoint')) {
      return Icons.slideshow_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(studentProfileProvider).valueOrNull;
    return GestureDetector(
      onTap: () => context.push(
        '/file/$lectureId/${file.id}',
        extra: {
          'filename': file.filename,
          'title': file.title,
          'mimeType': file.mimeType,
          'fileIvMap': fileIvMap,
          'watermarkConfig': watermarkConfig,
          'studentName': profile?.name ?? '',
          'studentEmail': profile?.email ?? '',
          'studentPhone': profile?.phone ?? '',
        },
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(_iconFor(file.mimeType),
                  color: Colors.amber.withValues(alpha: 0.75), size: 17),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  file.title.isNotEmpty ? file.title : file.filename,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: Colors.white24, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

// Attached quiz row — sits at the bottom of a _VideoGroup container.
class _AttachedQuizRow extends StatelessWidget {
  const _AttachedQuizRow({
    required this.quiz,
    required this.last,
    required this.lectureId,
    required this.videoId,
  });

  final Quiz quiz;
  final LocalQuizAttempt? last;
  final String lectureId;
  final String videoId;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push(
        '/quiz/$lectureId/${quiz.id}',
        extra: {'quiz': quiz, 'videoId': videoId},
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0x126C63FF),
          border: Border(top: BorderSide(color: Color(0x1A6C63FF))),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.quiz_rounded,
                  color: AppTheme.primary, size: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  quiz.title.isNotEmpty ? quiz.title : 'Quiz',
                  style:
                      const TextStyle(color: AppTheme.secondaryAccent, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (last != null) ...[
                Text(
                  '${last!.correctCount}/${last!.totalQuestions}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(width: 10),
              ],
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Take Quiz',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
