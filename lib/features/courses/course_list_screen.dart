import 'dart:io' show Platform;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/app_exception.dart';
import '../../core/version_info.dart';
import '../../features/auth/auth_providers.dart';
import '../../shared/widgets/app_drawer.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../quiz/quiz_provider.dart';
import 'announcements_provider.dart';
import 'courses_provider.dart';
import 'enrolled_courses_provider.dart';
import 'sec_file_intent_service.dart';
import 'sec_importer.dart';
import 'widgets/announcement_banner.dart';

class CourseListScreen extends ConsumerStatefulWidget {
  const CourseListScreen({super.key});

  @override
  ConsumerState<CourseListScreen> createState() => _CourseListScreenState();
}

class _CourseListScreenState extends ConsumerState<CourseListScreen> {
  ProviderSubscription<String?>? _intentSub;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _intentSub = ref.listenManual<String?>(
        pendingSecFileProvider,
        (_, filePath) {
          if (filePath == null) return;
          ref.read(pendingSecFileProvider.notifier).state = null;
          _handlePendingSecFile(filePath);
        },
        fireImmediately: true,
      );
    });
  }

  @override
  void dispose() {
    _intentSub?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _isRefreshing = true);
    try {
      await invalidateEnrolledCoursesCache();
      await Future.wait([
        ref.refresh(enrolledCoursesProvider.future),
        ref.refresh(activeAnnouncementsProvider.future),
      ]);
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _handlePendingSecFile(String filePath) async {
    final importer = ref.read(secImporterProvider);

    // Peek metadata without full extraction
    final Map<String, dynamic> meta;
    try {
      meta = await SecImporter.peekMetadata(filePath);
    } catch (e) {
      if (!mounted) return;
      _showError('Could not read .sec file: $e');
      return;
    }

    final version = meta['format_version'] as String? ?? '1.0';
    final courseId = (version == '2.0' || version == '2.1')
        ? meta['course_id'] as String? ?? ''
        : meta['course_id'] as String? ?? '';
    final lectureTitle = meta['lecture_title'] as String? ??
        meta['title'] as String? ??
        'Lecture';

    if (courseId.isEmpty) {
      _showError('Invalid .sec file: missing course ID.');
      return;
    }

    if (meta['package_type'] == 'quiz_collection') {
      await _handlePendingQuizCollectionFile(filePath, meta, courseId);
      return;
    }

    if (meta['package_type'] == 'update') {
      await _handlePendingUpdateFile(filePath, meta, courseId, lectureTitle);
      return;
    }

    // Enrollment check before touching heavy extraction
    final bool enrolled;
    try {
      enrolled = await SecImporter.checkEnrollment(courseId);
    } catch (e) {
      if (!mounted) return;
      _showError('Could not verify enrollment: $e');
      return;
    }

    if (!enrolled) {
      if (!mounted) return;
      _showNotEnrolledDialog(lectureTitle);
      return;
    }

    // Show progress sheet and run import
    if (!mounted) return;
    final progress = ValueNotifier<ImportProgress>(
      const ImportProgress(phase: ImportPhase.extracting),
    );

    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ImportProgressSheet(
        lectureTitle: lectureTitle,
        progress: progress,
      ),
    );

    try {
      final lectureId = await importer.importFromPath(
        filePath,
        onProgress: (p) => progress.value = p,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // close bottom sheet
      context.push('/course/$courseId');
      // Refresh lecture list so the newly imported lecture shows as imported
      ref.invalidate(courseLecturesProvider(courseId));
      // Refresh cached quiz content too — without this, a lecture opened
      // earlier in this app session keeps showing its pre-import quiz data
      // (e.g. a stale exportAllowed) until a full app restart.
      ref.invalidate(courseQuizzesProvider(lectureId));
    } on ImportException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError(e.message);
    } on KeyFetchException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError(e.message);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError('Import failed: $e');
    }
  }

  Future<void> _handlePendingQuizCollectionFile(
    String filePath,
    Map<String, dynamic> meta,
    String courseId,
  ) async {
    final importer = ref.read(secImporterProvider);
    final title = meta['title'] as String? ?? 'Quiz Collection';

    final bool enrolled;
    try {
      enrolled = await SecImporter.checkEnrollment(courseId);
    } catch (e) {
      if (!mounted) return;
      _showError('Could not verify enrollment: $e');
      return;
    }
    if (!enrolled) {
      if (!mounted) return;
      _showNotEnrolledDialog(title);
      return;
    }

    if (!mounted) return;
    final progress = ValueNotifier<ImportProgress>(
      const ImportProgress(phase: ImportPhase.extracting),
    );

    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ImportProgressSheet(
        lectureTitle: title,
        progress: progress,
      ),
    );

    try {
      final collectionId = await importer.importQuizCollection(
        filePath,
        onProgress: (p) => progress.value = p,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // close bottom sheet
      context.push('/course/$courseId');
      ref.invalidate(generalQuizCollectionsProvider(courseId));
      // See _handlePendingSecFile's comment — same staleness risk applies
      // to General Quiz collections.
      ref.invalidate(generalQuizzesProvider(collectionId));
    } on ImportException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError(e.message);
    } on KeyFetchException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError(e.message);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError('Import failed: $e');
    }
  }

  Future<void> _handlePendingUpdateFile(
    String filePath,
    Map<String, dynamic> meta,
    String courseId,
    String lectureTitle,
  ) async {
    final importer = ref.read(secImporterProvider);
    final description = meta['update_description'] as String? ?? '';

    final bool enrolled;
    try {
      enrolled = await SecImporter.checkEnrollment(courseId);
    } catch (e) {
      if (!mounted) return;
      _showError('Could not verify enrollment: $e');
      return;
    }
    if (!enrolled) {
      if (!mounted) return;
      _showNotEnrolledDialog(lectureTitle);
      return;
    }

    if (!mounted) return;
    final progress = ValueNotifier<ImportProgress>(
      const ImportProgress(phase: ImportPhase.extracting),
    );

    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ImportProgressSheet(
        lectureTitle: '$lectureTitle (update)',
        progress: progress,
      ),
    );

    try {
      await importer.applyUpdate(filePath, onProgress: (p) => progress.value = p);
      if (!mounted) return;
      Navigator.of(context).pop(); // close bottom sheet
      ref.invalidate(courseLecturesProvider(courseId));
      // See _handlePendingSecFile's comment — .secupdate correctly rewrites
      // quizzes.json on disk, but this cached provider still needs an
      // explicit refresh if the lecture was already opened this session.
      final updatedLectureId = meta['lecture_id'] as String?;
      if (updatedLectureId != null) {
        ref.invalidate(courseQuizzesProvider(updatedLectureId));
      }
      if (description.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            title: const Text('Lecture updated', style: TextStyle(color: Colors.white)),
            content: Text(description, style: const TextStyle(color: Colors.white70, height: 1.5)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK', style: TextStyle(color: Color(0xFF6C63FF))),
              ),
            ],
          ),
        );
      }
      if (!mounted) return;
      context.push('/course/$courseId');
    } on ImportException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError(e.message);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError('Update failed: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _showNotEnrolledDialog(String lectureTitle) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Not Enrolled',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'You are not enrolled in the course that contains "$lectureTitle".\n\n'
          'Ask your teacher to enroll you before importing this file.',
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK', style: TextStyle(color: Color(0xFF6C63FF))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bindingState = ref.watch(deviceBindingProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      drawer: const AppDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        title: const Text(
          'My Courses',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white70),
        actions: [
          // Windows has no touch/mouse-drag pull-to-refresh convention, so
          // the RefreshIndicator gesture below is effectively undiscoverable
          // there — give desktop users an explicit action instead.
          if (Platform.isWindows)
            IconButton(
              tooltip: 'Refresh',
              icon: _isRefreshing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white70),
                    )
                  : const Icon(Icons.refresh_rounded),
              onPressed: _isRefreshing ? null : _refresh,
            ),
          IconButton(
            tooltip: 'Review',
            icon: const Icon(Icons.style_rounded),
            onPressed: () => context.push('/review'),
          ),
        ],
      ),
      body: Column(
        children: [
          const AnnouncementBannerList(),
          Expanded(
            child: bindingState.when(
              loading: () => const Center(child: LoadingIndicator()),
              error: (error, _) {
                if (error is DeviceMismatchException) {
                  return _DeviceBlockedView(message: error.message);
                }
                if (error is ProfileNotFoundException) {
                  return _ProfileMissingView(
                      onSignOut: () => FirebaseAuth.instance.signOut());
                }
                if (error is AuthSessionExpiredException) {
                  return _SessionExpiredView(
                      onSignOut: () => FirebaseAuth.instance.signOut());
                }
                return _ErrorView(message: error.toString());
              },
              data: (_) => _EnrolledCoursesList(),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Shows exactly which git commit this build is from, so a
                  // stale install is visible at a glance instead of assumed
                  // to be current (an "+dirty" suffix means uncommitted
                  // changes were present when this build was made).
                  Text(
                    kVersionDisplay,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.12),
                      fontSize: 9,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EnrolledCoursesList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coursesAsync = ref.watch(enrolledCoursesProvider);
    return RefreshIndicator(
      onRefresh: () async {
        await invalidateEnrolledCoursesCache();
        await Future.wait([
          ref.refresh(enrolledCoursesProvider.future),
          ref.refresh(activeAnnouncementsProvider.future),
        ]);
      },
      color: const Color(0xFF6C63FF),
      backgroundColor: const Color(0xFF1A1A2E),
      child: coursesAsync.when(
        loading: () => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 300, child: Center(child: LoadingIndicator())),
          ],
        ),
        error: (e, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (e is AuthSessionExpiredException)
              _SessionExpiredView(
                  onSignOut: () => FirebaseAuth.instance.signOut())
            else
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.wifi_off_rounded,
                        color: Colors.white38, size: 56),
                    const SizedBox(height: 16),
                    const Text(
                      'Could not load courses.\nCheck your connection.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: () async {
                        await invalidateEnrolledCoursesCache();
                        ref.invalidate(enrolledCoursesProvider);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
          ],
        ),
        data: (courses) {
          if (courses.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [_EmptyState()],
            );
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final columns = width >= 900
                  ? 4
                  : width >= 600
                      ? 3
                      : 2;
              return GridView.builder(
                padding: const EdgeInsets.all(16),
                physics: const AlwaysScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.85,
                ),
                itemCount: courses.length,
                itemBuilder: (_, i) {
                  final course = courses[i];
                  return _CourseGridCard(
                    course: course,
                    onTap: () => context.push(
                      '/course/${course.courseId}',
                      extra: {'title': course.title},
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _CourseGridCard extends StatelessWidget {
  const _CourseGridCard({required this.course, required this.onTap});

  final EnrolledCourse course;
  final VoidCallback onTap;

  static const _palette = [
    [Color(0xFF6C63FF), Color(0xFF3B37CC)],
    [Color(0xFF11998e), Color(0xFF38ef7d)],
    [Color(0xFFf7971e), Color(0xFFffd200)],
    [Color(0xFFc94b4b), Color(0xFF4b134f)],
    [Color(0xFF005C97), Color(0xFF363795)],
    [Color(0xFF42275a), Color(0xFF734b6d)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _palette[course.courseId.hashCode.abs() % _palette.length];
    final monogram = course.title.isNotEmpty
        ? course.title.trimLeft()[0].toUpperCase()
        : '?';

    Widget thumbnail;
    if (course.coverImageUrl != null && course.coverImageUrl!.isNotEmpty) {
      thumbnail = CachedNetworkImage(
        imageUrl: course.coverImageUrl!,
        // Ties the cache entry to the version Studio bumps on every
        // re-upload, so a replaced cover actually refreshes instead of
        // serving whatever was cached under the same R2 URL before.
        cacheKey: '${course.courseId}_v${course.coverImageVersion}',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        placeholder: (_, __) =>
            _GradientMonogram(colors: colors, monogram: monogram),
        errorWidget: (_, __, ___) =>
            _GradientMonogram(colors: colors, monogram: monogram),
      );
    } else {
      thumbnail = _GradientMonogram(colors: colors, monogram: monogram);
    }

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: const Color(0xFF1A1A2E),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Cover image or gradient thumbnail
              Expanded(
                flex: 55,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                  child: thumbnail,
                ),
              ),
              // Info section
              Expanded(
                flex: 45,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        course.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (course.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          course.description,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GradientMonogram extends StatelessWidget {
  const _GradientMonogram({required this.colors, required this.monogram});
  final List<Color> colors;
  final String monogram;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Center(
        child: Text(
          monogram,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.9),
            fontSize: 52,
            fontWeight: FontWeight.bold,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.school_outlined,
              size: 72,
              color: Colors.white.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 20),
            const Text(
              'No courses yet',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Ask your teacher to enroll you\nin a course to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceBlockedView extends ConsumerWidget {
  const _DeviceBlockedView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.devices_other_rounded,
                size: 72, color: Colors.orangeAccent),
            const SizedBox(height: 20),
            const Text(
              'Device Not Registered',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () => ref.invalidate(deviceBindingProvider),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Check Again'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => FirebaseAuth.instance.signOut(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orangeAccent,
                    side: const BorderSide(color: Colors.orangeAccent),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Sign Out'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileMissingView extends StatelessWidget {
  const _ProfileMissingView({required this.onSignOut});
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person_off_rounded,
                size: 72, color: Colors.orangeAccent),
            const SizedBox(height: 20),
            const Text(
              'Profile Incomplete',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Your account was created but your profile was not saved. '
              'Please sign out and register again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onSignOut,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign Out & Register Again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when FirestoreRest exhausts its own retry-with-force-refreshed-token
/// logic and still gets 401/403 — the local session is genuinely broken
/// (commonly after the app hasn't been opened in a while), not just a
/// momentarily-stale cached token a retry could fix. Signing out clears it;
/// the router's authStateChanges-driven redirect sends the student to
/// /login automatically once FirebaseAuth.instance.signOut() completes, so
/// there's no need to navigate manually here (same pattern as
/// _ProfileMissingView above).
class _SessionExpiredView extends StatelessWidget {
  const _SessionExpiredView({required this.onSignOut});
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_clock_rounded,
                size: 72, color: Colors.orangeAccent),
            const SizedBox(height: 20),
            const Text(
              'Session Needs Refreshing',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Your login session has gone stale — this can happen after "
              "the app hasn't been opened for a while. Sign out and back "
              "in to fix it.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onSignOut,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign Out & Sign In Again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 60, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportProgressSheet extends StatelessWidget {
  const _ImportProgressSheet({
    required this.lectureTitle,
    required this.progress,
  });

  final String lectureTitle;
  final ValueNotifier<ImportProgress> progress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: ValueListenableBuilder<ImportProgress>(
        valueListenable: progress,
        builder: (_, p, __) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Icon(Icons.download_rounded,
                      color: Color(0xFF6C63FF), size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Importing "$lectureTitle"',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              LinearProgressIndicator(
                value: p.progress,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 12),
              Text(
                p.label,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          );
        },
      ),
    );
  }
}
