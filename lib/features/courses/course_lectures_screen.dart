import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/app_exception.dart';
import '../../shared/widgets/app_drawer.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../core/models/announcement_model.dart';
import '../quiz/quiz_provider.dart';
import 'announcements_provider.dart';
import 'courses_provider.dart';
import 'enrolled_courses_provider.dart';
import 'sec_importer.dart';
import 'widgets/announcement_banner.dart';

class CourseLecturesScreen extends ConsumerStatefulWidget {
  const CourseLecturesScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
  });

  final String courseId;
  final String courseTitle;

  @override
  ConsumerState<CourseLecturesScreen> createState() =>
      _CourseLecturesScreenState();
}

class _CourseLecturesScreenState extends ConsumerState<CourseLecturesScreen> {
  final _progressNotifier = ValueNotifier<ImportProgress>(
      const ImportProgress(phase: ImportPhase.pickingFile));

  List<LectureSummary> _lectures = [];
  CreatedAtCursor? _lecturesCursor;
  bool _hasMoreLectures = true;
  bool _loadingMoreLectures = false;

  List<GeneralQuizCollectionSummary> _collections = [];
  CreatedAtCursor? _collectionsCursor;
  bool _hasMoreCollections = true;
  bool _loadingMoreCollections = false;

  bool _initialLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _progressNotifier.dispose();
    super.dispose();
  }

  Future<void> _refreshLectures() async {
    final page = await fetchCourseLecturesPage(courseId: widget.courseId);
    if (!mounted) return;
    setState(() {
      _lectures = page.items;
      _lecturesCursor = page.nextCursor;
      _hasMoreLectures = page.nextCursor != null;
    });
  }

  Future<void> _refreshCollections() async {
    final page = await fetchCourseGeneralQuizzesPage(courseId: widget.courseId);
    if (!mounted) return;
    setState(() {
      _collections = page.items;
      _collectionsCursor = page.nextCursor;
      _hasMoreCollections = page.nextCursor != null;
    });
  }

  Future<void> _loadMoreLectures() async {
    if (_lecturesCursor == null || _loadingMoreLectures) return;
    setState(() => _loadingMoreLectures = true);
    try {
      final page = await fetchCourseLecturesPage(
        courseId: widget.courseId,
        after: _lecturesCursor,
      );
      if (!mounted) return;
      setState(() {
        _lectures = [..._lectures, ...page.items];
        _lecturesCursor = page.nextCursor;
        _hasMoreLectures = page.nextCursor != null;
      });
    } finally {
      if (mounted) setState(() => _loadingMoreLectures = false);
    }
  }

  Future<void> _loadMoreCollections() async {
    if (_collectionsCursor == null || _loadingMoreCollections) return;
    setState(() => _loadingMoreCollections = true);
    try {
      final page = await fetchCourseGeneralQuizzesPage(
        courseId: widget.courseId,
        after: _collectionsCursor,
      );
      if (!mounted) return;
      setState(() {
        _collections = [..._collections, ...page.items];
        _collectionsCursor = page.nextCursor;
        _hasMoreCollections = page.nextCursor != null;
      });
    } finally {
      if (mounted) setState(() => _loadingMoreCollections = false);
    }
  }

  Future<void> _import(BuildContext context) async {
    _progressNotifier.value =
        const ImportProgress(phase: ImportPhase.pickingFile);

    // Capture before the async gap so context is never used after await.
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    Future.delayed(Duration.zero, () {
      if (!context.mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => ValueListenableBuilder<ImportProgress>(
          valueListenable: _progressNotifier,
          builder: (_, progress, __) =>
              _ImportProgressDialog(progress: progress),
        ),
      );
    });

    try {
      final importer = ref.read(secImporterProvider);
      final lectureId = await importer.importSecFile(
        onProgress: (p) => _progressNotifier.value = p,
      );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Lecture imported!'),
          backgroundColor: Colors.green,
        ),
      );
      unawaited(_refreshLectures());
      ref.invalidate(localCoursesProvider);
      // Without this, a lecture opened earlier in this app session keeps
      // showing its pre-import quiz data (e.g. a stale exportAllowed) until
      // a full app restart.
      ref.invalidate(courseQuizzesProvider(lectureId));
    } on ImportException catch (e) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
    } on KeyFetchException catch (e) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text('Import failed: $e'),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _importQuizCollection(BuildContext context) async {
    _progressNotifier.value =
        const ImportProgress(phase: ImportPhase.pickingFile);

    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    Future.delayed(Duration.zero, () {
      if (!context.mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => ValueListenableBuilder<ImportProgress>(
          valueListenable: _progressNotifier,
          builder: (_, progress, __) =>
              _ImportProgressDialog(progress: progress),
        ),
      );
    });

    try {
      final importer = ref.read(secImporterProvider);
      final collectionId = await importer.importQuizCollectionFile(
        onProgress: (p) => _progressNotifier.value = p,
      );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Quiz collection imported!'),
          backgroundColor: Colors.green,
        ),
      );
      unawaited(_refreshCollections());
      ref.invalidate(generalQuizzesProvider(collectionId));
    } on ImportException catch (e) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
    } on KeyFetchException catch (e) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text('Import failed: $e'),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _refresh() async {
    setState(() { _initialLoading = _lectures.isEmpty; _error = null; });
    try {
      await Future.wait([
        _refreshLectures(),
        _refreshCollections(),
        ref.refresh(activeAnnouncementsProvider.future),
      ]);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _initialLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      drawer: const AppDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: Text(
          widget.courseTitle,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        // Windows has no touch/mouse-drag pull-to-refresh convention, so
        // RefreshIndicator's gesture is effectively undiscoverable there —
        // give desktop users an explicit action instead.
        actions: [
          if (Platform.isWindows)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Colors.white),
              tooltip: 'Refresh',
              onPressed: _refresh,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _import(context),
        backgroundColor: const Color(0xFF6C63FF),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.file_open_rounded),
        label: const Text(
          'Import .sec',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: const Color(0xFF6C63FF),
        backgroundColor: const Color(0xFF1A1A2E),
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_initialLoading && _lectures.isEmpty && _collections.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 300, child: Center(child: LoadingIndicator())),
        ],
      );
    }
    if (_error != null && _lectures.isEmpty && _collections.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.wifi_off_rounded,
                    color: Colors.white38, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Could not load lectures.\nCheck your connection and try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _refresh,
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
      );
    }
    if (_lectures.isEmpty && _collections.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 300,
            child: Center(
              child: Text(
                'No lectures available yet.',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        if (_collections.isNotEmpty) ...[
          _GeneralQuizzesSection(
            collections: _collections,
            onImport: () => _importQuizCollection(context),
            hasMore: _hasMoreCollections,
            loadingMore: _loadingMoreCollections,
            onLoadMore: _loadMoreCollections,
          ),
          const SizedBox(height: 8),
        ],
        ..._lectures.map((lecture) => _LectureCard(
              lecture: lecture,
              onImported: () {
                unawaited(_refreshLectures());
                ref.invalidate(localCoursesProvider);
              },
            )),
        if (_hasMoreLectures)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loadingMoreLectures
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF6C63FF),
                      ),
                    )
                  : TextButton(
                      onPressed: _loadMoreLectures,
                      child: const Text(
                        'Load more',
                        style: TextStyle(color: Color(0xFF6C63FF)),
                      ),
                    ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _LectureCard extends ConsumerWidget {
  const _LectureCard({required this.lecture, required this.onImported});

  final LectureSummary lecture;
  final VoidCallback onImported;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateNotices = lecture.isImported
        ? ref.watch(lectureAnnouncementsProvider(lecture.lectureId)).valueOrNull ??
            const <AnnouncementModel>[]
        : const <AnnouncementModel>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (updateNotices.isNotEmpty)
          Padding(
            key: ValueKey('notice_${updateNotices.first.id}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: AnnouncementCard(
              announcement: updateNotices.first,
              lectureTitle: lecture.title,
            ),
          ),
        GestureDetector(
      // Stable identity independent of the notice above: the notice's
      // presence toggles as lectureAnnouncementsProvider (a
      // StreamProvider.autoDispose) resets and re-fetches, which shifts
      // this card's position in the Column. Without a key, Flutter's
      // positional reconciliation tears down and rebuilds this element on
      // that shift, killing any tap gesture already in flight against it.
      key: ValueKey('lecture_card_${lecture.lectureId}'),
      onTap: lecture.isImported
          ? () => context.push('/lecture/${lecture.lectureId}')
          : null,
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: lecture.isImported
              ? const Color(0xFF6C63FF).withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: lecture.isImported
                  ? const Color(0xFF6C63FF).withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              !lecture.isImported
                  ? Icons.lock_outline_rounded
                  : lecture.videoCount == 0
                      ? Icons.folder_open_rounded
                      : Icons.play_circle_filled_rounded,
              color: lecture.isImported
                  ? const Color(0xFF6C63FF)
                  : Colors.white24,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lecture.title,
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
                    if (lecture.isImported && lecture.videoCount == 0) ...[
                      const Icon(Icons.folder_open_rounded,
                          color: Colors.white38, size: 13),
                      const SizedBox(width: 4),
                      const Text(
                        'Files only',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ] else ...[
                      if (lecture.videoCount > 0) ...[
                        const Icon(Icons.video_library_rounded,
                            color: Colors.white38, size: 13),
                        const SizedBox(width: 4),
                        Text(
                          '${lecture.videoCount} video${lecture.videoCount == 1 ? '' : 's'}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (lecture.durationSeconds > 0) ...[
                        const Icon(Icons.access_time_rounded,
                            color: Colors.white38, size: 13),
                        const SizedBox(width: 4),
                        Text(
                          lecture.formattedDuration,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (lecture.isImported)
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white38, size: 22),
        ],
      ),
      ),
    ),
      ],
    );
  }
}

// ─── General Quizzes (standalone, course-level quiz collections) ─────────────
//
// Deliberately a separate section rather than interleaved into the lecture
// list above — a General Quiz collection has no video/lecture of its own,
// and _LectureCard's tap-key stability fix (tied to the live announcement
// banner above it) is specific to lecture rows.

class _GeneralQuizzesSection extends StatelessWidget {
  const _GeneralQuizzesSection({
    required this.collections,
    required this.onImport,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final List<GeneralQuizCollectionSummary> collections;
  final VoidCallback onImport;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.quiz_rounded, color: Colors.white38, size: 15),
            const SizedBox(width: 6),
            const Text(
              'GENERAL QUIZZES',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_open_rounded,
                  size: 15, color: Color(0xFF6C63FF)),
              label: const Text(
                'Import .secquiz',
                style: TextStyle(color: Color(0xFF6C63FF), fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ...collections.map((c) => _GeneralQuizCollectionCard(
              key: ValueKey('general_quiz_${c.collectionId}'),
              collection: c,
            )),
        if (hasMore)
          Center(
            child: loadingMore
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF6C63FF),
                      ),
                    ),
                  )
                : TextButton(
                    onPressed: onLoadMore,
                    child: const Text(
                      'Load more quizzes',
                      style: TextStyle(color: Color(0xFF6C63FF), fontSize: 12),
                    ),
                  ),
          ),
      ],
    );
  }
}

class _GeneralQuizCollectionCard extends ConsumerWidget {
  const _GeneralQuizCollectionCard({
    super.key,
    required this.collection,
  });

  final GeneralQuizCollectionSummary collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: collection.isImported
          ? () => context.push(
                '/general-quiz/${collection.collectionId}',
                extra: {'title': collection.title},
              )
          : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: collection.isImported
                ? const Color(0xFF6C63FF).withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: collection.isImported
                    ? const Color(0xFF6C63FF).withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                collection.isImported
                    ? Icons.quiz_rounded
                    : Icons.lock_outline_rounded,
                color: collection.isImported
                    ? const Color(0xFF6C63FF)
                    : Colors.white24,
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.title,
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
                      const Icon(Icons.help_outline_rounded,
                          color: Colors.white38, size: 13),
                      const SizedBox(width: 4),
                      Text(
                        '${collection.questionCount} question${collection.questionCount == 1 ? '' : 's'}',
                        style:
                            const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (collection.isImported)
              const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38, size: 22),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ImportProgressDialog extends StatelessWidget {
  const _ImportProgressDialog({required this.progress});
  final ImportProgress progress;

  @override
  Widget build(BuildContext context) {
    final pct = progress.progress;
    return Dialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline_rounded,
                color: Color(0xFF6C63FF), size: 40),
            const SizedBox(height: 16),
            const Text(
              'Importing Lecture',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 8,
                backgroundColor: Colors.white12,
                color: const Color(0xFF6C63FF),
              ),
            ),
            const SizedBox(height: 12),
            if (pct != null)
              Text(
                '${(pct * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                  color: Color(0xFF6C63FF),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            const SizedBox(height: 4),
            Text(
              progress.label,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
