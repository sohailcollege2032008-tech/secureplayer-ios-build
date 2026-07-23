import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/quiz_db_service.dart';
import '../export/quiz_export_sheet.dart';
import 'review_deck.dart';
import 'review_providers.dart';
import 'widgets/filter_mode_picker.dart';
import '../../app/theme.dart';

/// Scope picker: choose one lecture, several lectures, or whole courses to
/// review. Entry point is the Review icon on the My Courses AppBar.
class ReviewScopeScreen extends ConsumerStatefulWidget {
  const ReviewScopeScreen({super.key});

  @override
  ConsumerState<ReviewScopeScreen> createState() => _ReviewScopeScreenState();
}

class _ReviewScopeScreenState extends ConsumerState<ReviewScopeScreen> {
  final Set<String> _selected = {};
  ReviewFilterMode _filterMode = ReviewFilterMode.wholeExam;
  // Only shown/meaningful once 2+ sources are selected.
  bool _shuffleAcrossSources = false;

  @override
  Widget build(BuildContext context) {
    final overviewAsync = ref.watch(reviewScopeOverviewProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        foregroundColor: Colors.white,
        title: const Text(
          'Review',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.star_rounded, color: Colors.amber),
            tooltip: 'Starred Questions',
            onPressed: () => context.push('/review/starred-scope'),
          ),
        ],
      ),
      body: overviewAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(
          child: Text('Could not load lectures: $e',
              style: const TextStyle(color: Colors.white70)),
        ),
        data: (groups) {
          if (groups.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.quiz_outlined, color: Colors.white24, size: 64),
                    SizedBox(height: 16),
                    Text(
                      'No quiz questions to review yet.\nImport a lecture that has quizzes first.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  ],
                ),
              ),
            );
          }
          return _buildPicker(groups);
        },
      ),
    );
  }

  Widget _buildPicker(List<ReviewCourseGroup> groups) {
    final selectedDue = groups
        .expand((g) => g.lectures)
        .where((l) => _selected.contains(l.lectureId))
        .fold(0, (sum, l) => sum + l.dueCount);

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: groups.length,
            itemBuilder: (_, i) => _buildCourseCard(groups[i]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _buildFilterModePicker(),
        ),
        if (_selected.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _shuffleAcrossSources,
              onChanged: (v) => setState(() => _shuffleAcrossSources = v),
              activeThumbColor: AppTheme.primary,
              title: const Text(
                'Shuffle questions across sources',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: const Text(
                'Off keeps each source grouped together, in the order selected',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _selected.isEmpty ? null : _startSession,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.white12,
                      disabledForegroundColor: Colors.white38,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: Text(
                      _selected.isEmpty
                          ? 'Select lectures to review'
                          : selectedDue > 0
                              ? 'Start Review ($selectedDue due)'
                              : 'Review (all caught up)',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                  ),
                ),
                if (_selected.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _exportSelected,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primary,
                      side: const BorderSide(color: AppTheme.primary),
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Icon(Icons.ios_share_rounded),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _exportSelected() async {
    final lectureIds = _selected.toList();
    final messenger = ScaffoldMessenger.of(context);

    List<ReviewQuestion> questions;
    try {
      final quizzesByLecture = {
        for (final id in lectureIds) id: await quizzesForScopeId(ref, id),
      };
      final srsRows =
          await QuizDbService.instance.srsRowsForLectures(lectureIds);
      final needsStarred = _filterMode == ReviewFilterMode.starredOnly ||
          _filterMode == ReviewFilterMode.starredOrWrong;
      final starredKeys = needsStarred
          ? await QuizDbService.instance.starredKeysForLectures(lectureIds)
          : const <String>{};
      final deck = buildReviewDeck(
        quizzesByLecture: quizzesByLecture,
        srsRows: srsRows,
        now: DateTime.now(),
        filterMode: _filterMode,
        starredKeys: starredKeys,
      );
      // Practice mode includes everything in scope (due + never-seen +
      // not-yet-due) — an export should cover the whole selected scope, not
      // just what's due today.
      questions = deck.sessionList(practice: true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not build deck: $e')));
      return;
    }

    if (questions.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No questions in this scope.')));
      return;
    }

    if (!mounted) return;
    await showReviewExportSheet(
      context,
      ref,
      questions: questions,
      deckName: lectureIds.length == 1 ? 'Review Deck' : 'Review Deck (${lectureIds.length} sources)',
    );
  }

  void _startSession() {
    context.push('/review/session', extra: {
      'lectureIds': _selected.toList(),
      'filterMode': _filterMode.name,
      'shuffleAcrossSources': _shuffleAcrossSources,
    }).then((_) {
      // Ratings changed due counts — refresh the picker on return.
      ref.invalidate(reviewScopeOverviewProvider);
    });
  }

  Widget _buildFilterModePicker() {
    return FilterModePicker(
      value: _filterMode,
      onChanged: (mode) => setState(() => _filterMode = mode),
    );
  }

  Widget _buildCourseCard(ReviewCourseGroup group) {
    final lectureIds = group.lectures.map((l) => l.lectureId).toSet();
    final selectedCount = lectureIds.where(_selected.contains).length;
    final allSelected = selectedCount == lectureIds.length;
    final noneSelected = selectedCount == 0;
    final isPersonal = group.parentCourseId == kPersonalQuizGroupId;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPersonal
              ? Colors.amber.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Course header row: tri-state checkbox toggles all lectures.
          CheckboxListTile(
            value: allSelected ? true : (noneSelected ? false : null),
            tristate: true,
            onChanged: (_) => setState(() {
              if (allSelected) {
                _selected.removeAll(lectureIds);
              } else {
                _selected.addAll(lectureIds);
              }
            }),
            activeColor: AppTheme.primary,
            checkColor: Colors.white,
            side: const BorderSide(color: Colors.white38),
            controlAffinity: ListTileControlAffinity.leading,
            title: Row(
              children: [
                if (isPersonal) ...[
                  const Icon(Icons.edit_note_rounded,
                      color: Colors.amber, size: 16),
                  const SizedBox(width: 6),
                ],
                Text(
                  group.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            secondary: _dueBadge(group.dueCount, group.totalQuestions),
          ),
          const Divider(height: 1, color: Color(0x14FFFFFF)),
          ...group.lectures.map(_buildLectureRow),
        ],
      ),
    );
  }

  Widget _buildLectureRow(ReviewLectureInfo lecture) {
    final selected = _selected.contains(lecture.lectureId);
    return CheckboxListTile(
      value: selected,
      onChanged: (_) => setState(() {
        selected
            ? _selected.remove(lecture.lectureId)
            : _selected.add(lecture.lectureId);
      }),
      activeColor: AppTheme.primary,
      checkColor: Colors.white,
      side: const BorderSide(color: Colors.white24),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.only(left: 28, right: 16),
      title: Text(
        lecture.lectureTitle,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      secondary: _dueBadge(lecture.dueCount, lecture.totalQuestions),
    );
  }

  Widget _dueBadge(int due, int total) {
    final active = due > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? AppTheme.primary.withValues(alpha: 0.15)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$due due · $total',
        style: TextStyle(
          color: active ? AppTheme.secondaryAccent : Colors.white38,
          fontSize: 11,
          fontWeight: active ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
