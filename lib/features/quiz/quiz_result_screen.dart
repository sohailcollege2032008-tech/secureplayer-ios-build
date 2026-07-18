import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/quiz_db_service.dart';
import '../export/quiz_export_sheet.dart';
import '../review/review_deck.dart';
import '../review/review_settings_provider.dart';
import '../review/widgets/filter_mode_picker.dart';
import 'quiz_attempt_result.dart';
import 'quiz_history_service.dart';
import 'quiz_provider.dart';
import 'review_sync_service.dart';

class QuizResultScreen extends ConsumerStatefulWidget {
  const QuizResultScreen({super.key, required this.result});

  final QuizAttemptResult result;

  @override
  ConsumerState<QuizResultScreen> createState() => _QuizResultScreenState();
}

class _QuizResultScreenState extends ConsumerState<QuizResultScreen> {
  bool _saved = false;
  // Gates the "View Quiz Analytics" button — no point showing it until
  // there's a second attempt to actually compare against.
  bool _isFirstAttempt = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _saveResult());
  }

  Future<void> _saveResult() async {
    if (_saved) return;
    _saved = true;
    final r = widget.result;
    final service = ref.read(quizHistoryServiceProvider);
    final isFirst = await service.isFirstAttempt(r.quiz.id);
    await service.insertAttempt(r);
    if (mounted) setState(() => _isFirstAttempt = isFirst);

    // Always logged for history/stats — never affects SRS scheduling itself
    // (see review_sync_service.dart for the one place that's allowed to).
    for (int i = 0; i < r.quiz.questions.length; i++) {
      final q = r.quiz.questions[i];
      final selected = i < r.selectedIndices.length ? r.selectedIndices[i] : -1;
      if (selected < 0) continue;
      await QuizDbService.instance.recordAttempt(
        question: q,
        quizId: r.quiz.id,
        lectureId: r.lectureId,
        courseId: r.quiz.courseId,
        selectedIndex: selected,
      );
    }

    if (r.quiz.isPopupQuiz) return; // popups never enter review at all

    if (isFirst) {
      // The only case whose results sync to review automatically.
      await syncAttemptToReview(
        r,
        scope: ReviewFilterMode.wholeExam,
        settings: ref.read(reviewSettingsProvider),
      );
    } else if (mounted) {
      await _maybeUpdateReviewFromRetake(r);
    }
  }

  Future<void> _maybeUpdateReviewFromRetake(QuizAttemptResult r) async {
    final wantsUpdate = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Update review questions?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Use this attempt\'s results for spaced-repetition review instead '
          'of what\'s currently there? This replaces the review schedule for '
          'this quiz\'s questions — it does not add to it.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes', style: TextStyle(color: Color(0xFF9C95FF))),
          ),
        ],
      ),
    );
    if (wantsUpdate != true || !mounted) return;

    var scope = ReviewFilterMode.wholeExam;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Which questions go to review?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                FilterModePicker(
                  value: scope,
                  onChanged: (mode) => setSheetState(() => scope = mode),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C63FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: const Text('Confirm',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true) return;

    await syncAttemptToReview(
      r,
      scope: scope,
      settings: ref.read(reviewSettingsProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final pct = r.scorePercent;
    final Color scoreColor = pct >= 0.7
        ? Colors.greenAccent
        : pct >= 0.5
            ? Colors.orangeAccent
            : Colors.redAccent;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: const Text(
          'Quiz Result',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: 'Export quiz',
            onPressed: () => showQuizExportSheet(
              context,
              ref,
              quiz: r.quiz,
              lectureId: r.lectureId,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 16),
            _buildScoreCircle(r, scoreColor),
            const SizedBox(height: 24),
            Text(
              r.quiz.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.access_time_rounded,
                    color: Colors.white38, size: 16),
                const SizedBox(width: 6),
                Text(
                  r.formattedTime,
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Review',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            ...List.generate(r.quiz.questions.length, (i) =>
                _buildQuestionReview(r, i)),
            const SizedBox(height: 32),
            if (!r.quiz.isPopupQuiz && !_isFirstAttempt)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push(
                      '/quiz-analytics/${r.quiz.id}',
                      extra: {'title': r.quiz.title},
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF6C63FF),
                      side: const BorderSide(color: Color(0xFF6C63FF)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.insights_rounded),
                    label: const Text(
                      'View Quiz Analytics',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  if (widget.result.isPopupSource) {
                    context.pop(true);
                  } else {
                    context.pop();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: Text(
                  widget.result.isPopupSource ? 'Continue Watching' : 'Done',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCircle(QuizAttemptResult r, Color color) {
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 120,
          height: 120,
          child: CircularProgressIndicator(
            value: r.scorePercent,
            strokeWidth: 10,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        Column(
          children: [
            Text(
              '${r.correctCount}',
              style: TextStyle(
                color: color,
                fontSize: 36,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '/ ${r.totalQuestions}',
              style: const TextStyle(color: Colors.white54, fontSize: 16),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQuestionReview(QuizAttemptResult r, int i) {
    final q = r.quiz.questions[i];
    final selected = i < r.selectedIndices.length ? r.selectedIndices[i] : -1;
    final isCorrect = selected == q.correctIndex;
    final starred = ref.watch(starredProvider(r.quiz.courseId));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCorrect
              ? Colors.greenAccent.withValues(alpha: 0.25)
              : Colors.redAccent.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCorrect ? Icons.check_circle_rounded : Icons.cancel_rounded,
                color: isCorrect ? Colors.greenAccent : Colors.redAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Q${i + 1}: ${q.text}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () => ref.read(starredProvider(r.quiz.courseId).notifier).toggle(
                      questionId: q.id,
                      quizId: r.quiz.id,
                      lectureId: r.lectureId,
                    ),
                child: Icon(
                  starred.isStarred(q.id) ? Icons.star_rounded : Icons.star_border_rounded,
                  color: starred.isStarred(q.id)
                      ? Colors.amber
                      : Colors.white30,
                  size: 20,
                ),
              ),
            ],
          ),
          if (!isCorrect && selected >= 0) ...[
            const SizedBox(height: 6),
            Text(
              'Your answer: ${q.options[selected]}',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
            Text(
              'Correct: ${q.options[q.correctIndex]}',
              style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
            ),
          ],
          if (q.explanation.isNotEmpty && !isCorrect) ...[
            const SizedBox(height: 6),
            Text(
              q.explanation,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
