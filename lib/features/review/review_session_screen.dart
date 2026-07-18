import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/quiz_db_service.dart';
import '../../core/services/srs_scheduler.dart';
import '../../local_server/server_provider.dart';
import '../../security_layer/runtime_guard/security_guard_gate.dart';
import '../../security_layer/runtime_guard/security_runtime_guard_mixin.dart';
import '../../shared/encrypted_image_cache_mixin.dart';
import '../../shared/widgets/question_image_block.dart';
import '../quiz/quiz_nav_gesture_wrapper.dart';
import '../quiz/quiz_provider.dart';
import '../quiz/quiz_settings_provider.dart';
import '../quiz/quiz_text_styles.dart';
import 'review_deck.dart';
import 'review_providers.dart';
import 'review_settings_provider.dart';
import 'review_settings_screen.dart';
import 'widgets/rating_bar.dart';

/// A spaced-repetition review session over the selected lectures' due
/// questions. Flow per question: answer -> feedback + explanation -> ALWAYS
/// all four rating buttons -> next. غلط re-enqueues the question later in
/// the same session (Anki-style), deferred until its cooldown elapses (see
/// _goNext). Swipe/arrow-key navigation moves freely forward or backward
/// regardless of whether the current question has been answered/rated yet
/// — mirroring quiz-taking's own navigation exactly; a skipped question is
/// simply never written and stays exactly as due as before. No Firestore
/// anywhere in this feature.
class ReviewSessionScreen extends ConsumerStatefulWidget {
  const ReviewSessionScreen({
    super.key,
    required this.lectureIds,
    this.filterMode = ReviewFilterMode.wholeExam,
    this.shuffleAcrossSources = false,
  });

  final List<String> lectureIds;
  final ReviewFilterMode filterMode;
  // Only meaningful with 2+ lectureIds selected. False (default) keeps
  // questions grouped by source in selection order, due-date ordered within
  // each group; true shuffles the combined due/never-seen list freely.
  final bool shuffleAcrossSources;

  @override
  ConsumerState<ReviewSessionScreen> createState() =>
      _ReviewSessionScreenState();
}

enum _ViewState { loading, caughtUp, session, summary }

class _ReviewSessionScreenState extends ConsumerState<ReviewSessionScreen>
    with
        EncryptedImageCacheMixin<ReviewSessionScreen>,
        WidgetsBindingObserver,
        SecurityRuntimeGuardMixin {
  _ViewState _view = _ViewState.loading;
  ReviewDeck? _builtDeck;

  // Session state — per-index so navigating away from and back to a
  // question (free navigation, see class doc) restores its own state
  // instead of bleeding into whatever's currently displayed.
  List<ReviewQuestion> _deck = [];
  int _index = 0;
  final Map<int, int> _selectedByIndex = {};
  final Set<int> _submittedIndices = {};
  final Set<int> _ratedIndices = {};
  // Session-level only (never persisted) — when each question-key was last
  // displayed, so a just-rated "again" question can't resurface before its
  // configured cooldown even within this same session.
  final Map<String, DateTime> _lastShownAt = {};
  final Map<ReviewRating, int> _ratingCounts = {};
  final Set<String> _uniqueReviewed = {};

  int? get _selected => _selectedByIndex[_index];
  bool get _submitted => _submittedIndices.contains(_index);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    startSecurityGuard();
    _buildDeck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopSecurityGuard();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      notifyAppResumedForSecurity();
    }
  }

  List<ReviewQuestion> _applyOrdering(List<ReviewQuestion> list) {
    if (widget.shuffleAcrossSources) {
      return [...list]..shuffle();
    }
    final ordered = [...list];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    ordered.sort((a, b) {
      final ia = widget.lectureIds.indexOf(a.lectureId);
      final ib = widget.lectureIds.indexOf(b.lectureId);
      if (ia != ib) return ia.compareTo(ib);
      return (a.srs?.dueAt ?? epoch).compareTo(b.srs?.dueAt ?? epoch);
    });
    return ordered;
  }

  Future<void> _buildDeck() async {
    try {
      final quizzesByLecture = {
        for (final id in widget.lectureIds)
          id: await quizzesForScopeId(ref, id),
      };
      final srsRows =
          await QuizDbService.instance.srsRowsForLectures(widget.lectureIds);
      final needsStarred = widget.filterMode == ReviewFilterMode.starredOnly ||
          widget.filterMode == ReviewFilterMode.starredOrWrong;
      final starredKeys = needsStarred
          ? await QuizDbService.instance
              .starredKeysForLectures(widget.lectureIds)
          : const <String>{};
      final deck = buildReviewDeck(
        quizzesByLecture: quizzesByLecture,
        srsRows: srsRows,
        now: DateTime.now(),
        filterMode: widget.filterMode,
        starredKeys: starredKeys,
      );
      if (!mounted) return;
      setState(() {
        _builtDeck = deck;
        if (deck.dueCount > 0) {
          _deck = _applyOrdering(deck.sessionList(practice: false));
          _stampShown(0);
          _view = _ViewState.session;
        } else {
          _view = _ViewState.caughtUp;
        }
      });
    } catch (_) {
      if (!mounted) return;
      // Treat a build failure like an empty deck rather than crashing.
      setState(() => _view = _ViewState.caughtUp);
    }
  }

  void _startPractice() {
    setState(() {
      _deck = _applyOrdering(_builtDeck!.sessionList(practice: true));
      _index = 0;
      _selectedByIndex.clear();
      _submittedIndices.clear();
      _ratedIndices.clear();
      _stampShown(0);
      _view = _ViewState.session;
    });
  }

  ReviewQuestion get _current => _deck[_index];

  String _keyOf(ReviewQuestion entry) => '${entry.question.id}::${entry.quizId}';

  void _stampShown(int index) {
    _lastShownAt[_keyOf(_deck[index])] = DateTime.now();
  }

  bool _isCoolingDown(ReviewQuestion entry, Duration cooldown) {
    final lastShown = _lastShownAt[_keyOf(entry)];
    if (lastShown == null) return false;
    return DateTime.now().difference(lastShown) < cooldown;
  }

  void _goPrevious() {
    if (_index == 0) return;
    setState(() {
      _index--;
      _stampShown(_index);
    });
  }

  void _goNext() {
    if (_index + 1 >= _deck.length) {
      setState(() => _view = _ViewState.summary);
      return;
    }
    final cooldown =
        Duration(seconds: ref.read(reviewSettingsProvider).cooldownSeconds);
    // Defer (not skip) any still-cooling-down entry by swapping it later in
    // the deck — every entry still gets shown eventually, just not before
    // its cooldown elapses. Falls back to whatever's left if literally
    // everything remaining is cooling down, rather than dead-ending.
    var candidate = _index + 1;
    while (candidate < _deck.length - 1 &&
        _isCoolingDown(_deck[candidate], cooldown)) {
      final tmp = _deck[candidate];
      _deck[candidate] = _deck[candidate + 1];
      _deck[candidate + 1] = tmp;
      candidate++;
    }
    setState(() {
      _index = candidate;
      _stampShown(_index);
    });
  }

  Future<void> _rate(ReviewRating rating) async {
    final entry = _current;

    // Append-only history — keeps stats/last-attempt features working.
    // Never touches SRS state itself (recordAttempt no longer does that at
    // all) — this screen computes and writes its own SRS state right below
    // using the student's actual rating, not a correct/incorrect-derived one.
    await QuizDbService.instance.recordAttempt(
      question: entry.question,
      quizId: entry.quizId,
      lectureId: entry.lectureId,
      courseId: entry.courseId,
      selectedIndex: _selected!,
    );

    final next = SrsScheduler.next(
      reps: entry.srs?.reps ?? 0,
      intervalMin: entry.srs?.intervalMin ?? 0,
      rating: rating,
      now: DateTime.now(),
      settings: ref.read(reviewSettingsProvider),
    );
    await QuizDbService.instance.upsertSrsState(
      questionId: entry.question.id,
      quizId: entry.quizId,
      lectureId: entry.lectureId,
      courseId: entry.courseId,
      next: next,
      rating: rating,
      reviewedAt: DateTime.now(),
    );

    _ratingCounts[rating] = (_ratingCounts[rating] ?? 0) + 1;
    _uniqueReviewed.add(_keyOf(entry));
    _ratedIndices.add(_index);

    if (rating == ReviewRating.again) {
      // Anki-style: repeat within this session with the fresh SRS snapshot —
      // _goNext()'s cooldown check decides when it's actually eligible to show.
      _deck.add(entry.withSrs(SrsRow(
        questionId: entry.question.id,
        quizId: entry.quizId,
        lectureId: entry.lectureId,
        courseId: entry.courseId,
        reps: next.reps,
        intervalMin: next.intervalMin,
        dueAt: next.dueAt,
        lastRating: rating.index,
        lastReviewed: DateTime.now(),
      )));
    }

    if (!mounted) return;
    _goNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: const Text(
          'Review',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded, color: Colors.white70),
            tooltip: 'Review settings',
            onPressed: () => showReviewSettingsSheet(context),
          ),
          if (_view == _ViewState.session)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_index + 1} / ${_deck.length}',
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
      body: SecurityGuardGate(
        child: switch (_view) {
          _ViewState.loading => const Center(
              child: CircularProgressIndicator(color: Color(0xFF6C63FF))),
          _ViewState.caughtUp => _buildCaughtUp(),
          _ViewState.session => _buildSession(),
          _ViewState.summary => _buildSummary(),
        },
      ),
    );
  }

  Widget _buildCaughtUp() {
    final nextDueAt = _builtDeck?.nextDueAt;
    final hasPractice = (_builtDeck?.totalQuestions ?? 0) > 0;
    String? nextLabel;
    if (nextDueAt != null) {
      final minutes = nextDueAt.difference(DateTime.now()).inSeconds / 60.0;
      nextLabel =
          'Next review in ${SrsScheduler.formatInterval(minutes < 1 ? 1 : minutes)}';
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.task_alt_rounded,
                color: Colors.greenAccent, size: 72),
            const SizedBox(height: 20),
            const Text(
              'All caught up!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (nextLabel != null) ...[
              const SizedBox(height: 8),
              Text(
                nextLabel,
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
            if (hasPractice) ...[
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: _startPractice,
                icon: const Icon(Icons.fitness_center_rounded, size: 18),
                label: const Text('Practice anyway'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSession() {
    final entry = _current;
    final styles = QuizTextStyles.forSettings(ref.watch(quizSettingsProvider));

    // Spin up the shelf server only when the current question has an image.
    // Personal-quiz questions never need one — their images are plain
    // local files.
    if (entry.question.hasImage) {
      if (entry.isPersonalQuiz) {
        WidgetsBinding.instance.addPostFrameCallback((_) =>
            loadPersonalImageIfNeeded(entry.quizId, entry.question.imageId));
      } else {
        final serverAsync = ref.watch(videoServerProvider(VideoPlaybackArgs(
          lectureId: entry.lectureId,
          videoId: '',
          watermarkEnabled: false,
        )));
        serverAsync.whenData((server) {
          WidgetsBinding.instance.addPostFrameCallback((_) => loadImageIfNeeded(
              entry.lectureId,
              entry.question.imageId,
              server.port,
              server.sessionToken));
        });
      }
    }

    final alreadyRated = _ratedIndices.contains(_index);
    final settings = ref.watch(quizSettingsProvider);

    return QuizNavGestureWrapper(
      enabled: settings.swipeNavigationEnabled,
      onNext: _goNext,
      onPrevious: _goPrevious,
      child: Column(
        children: [
          LinearProgressIndicator(
            value: (_index + 1) / _deck.length,
            backgroundColor: Colors.white12,
            color: const Color(0xFF6C63FF),
            minHeight: 3,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _buildQuestion(entry, styles),
                  const SizedBox(height: 24),
                  ..._buildOptions(entry, styles),
                  if (_submitted) ...[
                    const SizedBox(height: 20),
                    _buildFeedback(entry, styles),
                  ],
                  const SizedBox(height: 32),
                  if (!_submitted)
                    _buildSubmitButton()
                  else if (alreadyRated)
                    _buildAlreadyReviewedLabel()
                  else
                    RatingBar(
                      reps: entry.srs?.reps ?? 0,
                      intervalMin: entry.srs?.intervalMin ?? 0,
                      settings: ref.watch(reviewSettingsProvider),
                      onRate: _rate,
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlreadyReviewedLabel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: const Center(
        child: Text(
          'Already reviewed — swipe to continue',
          style: TextStyle(color: Colors.white38, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildQuestion(ReviewQuestion entry, QuizTextStyles styles) {
    final starred =
        ref.watch(starredProvider(entry.courseId)).isStarred(entry.question.id);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: QuestionTextWithImage(
            text: entry.question.text,
            hasImage: entry.question.hasImage,
            imageBytes: cachedImage(
                entry.isPersonalQuiz ? entry.quizId : entry.lectureId,
                entry.question.imageId),
            textStyle: styles.questionStyle,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(
            starred ? Icons.star_rounded : Icons.star_border_rounded,
            color: starred ? Colors.amber : Colors.white38,
          ),
          tooltip: starred ? 'Unstar' : 'Star for review',
          onPressed: () =>
              ref.read(starredProvider(entry.courseId).notifier).toggle(
                    questionId: entry.question.id,
                    quizId: entry.quizId,
                    lectureId: entry.lectureId,
                  ),
        ),
      ],
    );
  }

  List<Widget> _buildOptions(ReviewQuestion entry, QuizTextStyles styles) {
    final question = entry.question;
    return List.generate(question.options.length, (i) {
      Color? bgColor;
      Color borderColor = Colors.white12;
      Color textColor = Colors.white70;

      if (_submitted) {
        if (i == question.correctIndex) {
          bgColor = Colors.green.withValues(alpha: 0.15);
          borderColor = Colors.greenAccent;
          textColor = Colors.greenAccent;
        } else if (i == _selected) {
          bgColor = Colors.red.withValues(alpha: 0.12);
          borderColor = Colors.redAccent;
          textColor = Colors.redAccent;
        }
      } else if (i == _selected) {
        bgColor = const Color(0xFF6C63FF).withValues(alpha: 0.15);
        borderColor = const Color(0xFF6C63FF);
        textColor = Colors.white;
      }

      return GestureDetector(
        onTap: _submitted
            ? null
            : () => setState(() => _selectedByIndex[_index] = i),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: bgColor ?? Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor),
                  color: _submitted && i == _selected
                      ? (i == question.correctIndex
                          ? Colors.green.withValues(alpha: 0.3)
                          : Colors.red.withValues(alpha: 0.2))
                      : Colors.transparent,
                ),
                child: Center(
                  child: Text(
                    String.fromCharCode(65 + i),
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  question.options[i],
                  style: styles.optionStyle.copyWith(color: textColor),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildFeedback(ReviewQuestion entry, QuizTextStyles styles) {
    final isCorrect = _selected == entry.question.correctIndex;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isCorrect
            ? Colors.green.withValues(alpha: 0.1)
            : Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCorrect
              ? Colors.greenAccent.withValues(alpha: 0.3)
              : Colors.orange.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCorrect
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                color: isCorrect ? Colors.greenAccent : Colors.orangeAccent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                isCorrect ? 'Correct!' : 'Incorrect',
                style: styles.feedbackTitleStyle.copyWith(
                  color: isCorrect ? Colors.greenAccent : Colors.orangeAccent,
                ),
              ),
            ],
          ),
          if (entry.question.explanation.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              entry.question.explanation,
              style: styles.explanationStyle,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _selected == null
            ? null
            : () => setState(() => _submittedIndices.add(_index)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF6C63FF),
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.white12,
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        child: const Text(
          'Submit',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildSummary() {
    const ratingLabels = {
      ReviewRating.again: ('غلط', Colors.redAccent),
      ReviewRating.hard: ('صعب', Colors.orangeAccent),
      ReviewRating.medium: ('متوسط', Color(0xFF6C63FF)),
      ReviewRating.easy: ('سهل', Colors.greenAccent),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events_rounded,
                color: Color(0xFF6C63FF), size: 72),
            const SizedBox(height: 20),
            Text(
              'Session complete — ${_uniqueReviewed.length} question${_uniqueReviewed.length == 1 ? '' : 's'} reviewed',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final rating in ReviewRating.values)
                  if ((_ratingCounts[rating] ?? 0) > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: ratingLabels[rating]!.$2.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: ratingLabels[rating]!
                                .$2
                                .withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        '${ratingLabels[rating]!.$1} ${_ratingCounts[rating]}',
                        style: TextStyle(
                          color: ratingLabels[rating]!.$2,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
              ],
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 200,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: const Text('Done',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
