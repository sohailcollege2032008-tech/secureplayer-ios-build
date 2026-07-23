import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/quiz_db_service.dart';
import '../export/quiz_export_sheet.dart';
import 'review_deck.dart';
import 'review_providers.dart';
import '../../app/theme.dart';

/// Scope picker for the starred-questions library — same source picker as
/// [ReviewScopeScreen] (course/lecture checkboxes), but no filter mode and
/// no shuffle toggle: starred questions are just a plain browsable
/// repository, not a scheduled session.
class StarredScopeScreen extends ConsumerStatefulWidget {
  const StarredScopeScreen({super.key});

  @override
  ConsumerState<StarredScopeScreen> createState() =>
      _StarredScopeScreenState();
}

class _StarredScopeScreenState extends ConsumerState<StarredScopeScreen> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final overviewAsync = ref.watch(starredScopeOverviewProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        foregroundColor: Colors.white,
        title: const Text(
          'Starred Questions',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
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
                    Icon(Icons.star_border_rounded,
                        color: Colors.white24, size: 64),
                    SizedBox(height: 16),
                    Text(
                      'No starred questions yet.\nStar a question while taking a quiz or reviewing.',
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

  Widget _buildPicker(List<StarredCourseGroup> groups) {
    final selectedCount = groups
        .expand((g) => g.lectures)
        .where((l) => _selected.contains(l.lectureId))
        .fold(0, (sum, l) => sum + l.starredCount);

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: groups.length,
            itemBuilder: (_, i) => _buildCourseCard(groups[i]),
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
                    onPressed: _selected.isEmpty ? null : _openBrowse,
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
                          ? 'Select lectures to browse'
                          : 'Browse Starred ($selectedCount)',
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
      final starredKeys =
          await QuizDbService.instance.starredKeysForLectures(lectureIds);
      final deck = buildReviewDeck(
        quizzesByLecture: quizzesByLecture,
        srsRows: const {},
        now: DateTime.now(),
        filterMode: ReviewFilterMode.starredOnly,
        starredKeys: starredKeys,
      );
      questions = deck.sessionList(practice: true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not build deck: $e')));
      return;
    }

    if (questions.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('No starred questions in this scope.')));
      return;
    }

    if (!mounted) return;
    await showReviewExportSheet(
      context,
      ref,
      questions: questions,
      deckName: 'Starred Questions',
    );
  }

  void _openBrowse() {
    context.push('/review/starred', extra: {
      'lectureIds': _selected.toList(),
    }).then((_) {
      // Un-starring inside the browse screen changes counts here.
      ref.invalidate(starredScopeOverviewProvider);
    });
  }

  Widget _buildCourseCard(StarredCourseGroup group) {
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
            secondary: _starredBadge(group.starredCount),
          ),
          const Divider(height: 1, color: Color(0x14FFFFFF)),
          ...group.lectures.map(_buildLectureRow),
        ],
      ),
    );
  }

  Widget _buildLectureRow(StarredLectureInfo lecture) {
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
      secondary: _starredBadge(lecture.starredCount),
    );
  }

  Widget _starredBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: AppTheme.secondaryAccent, size: 12),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: const TextStyle(
              color: AppTheme.secondaryAccent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
