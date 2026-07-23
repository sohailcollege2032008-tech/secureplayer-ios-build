import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/quiz.dart';
import '../../core/models/quiz_progress.dart';
import '../../core/models/quiz_settings.dart';
import '../../core/services/quiz_db_service.dart';
import '../../local_server/server_provider.dart';
import '../../security_layer/runtime_guard/security_guard_gate.dart';
import '../../security_layer/runtime_guard/security_runtime_guard_mixin.dart';
import '../../shared/encrypted_image_cache_mixin.dart';
import 'quiz_attempt_result.dart';
import 'quiz_nav_gesture_wrapper.dart';
import 'quiz_question_body.dart';
import 'quiz_scroll_layout.dart';
import 'quiz_settings_provider.dart';
import 'quiz_settings_screen.dart';
import 'quiz_shuffle.dart';
import '../../app/theme.dart';

class QuizScreen extends ConsumerStatefulWidget {
  const QuizScreen({
    super.key,
    required this.quiz,
    required this.lectureId,
    this.videoId,
    this.isPopup = false,
  });

  final Quiz quiz;
  final String lectureId;
  final String? videoId;
  final bool isPopup;

  @override
  ConsumerState<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends ConsumerState<QuizScreen>
    with
        EncryptedImageCacheMixin<QuizScreen>,
        WidgetsBindingObserver,
        SecurityRuntimeGuardMixin {
  int _currentIndex = 0;
  bool _advancing = false;
  // One-shot guard per answer so a manual swipe-to-skip-the-wait and the
  // pending Future.delayed auto-advance can't both fire the same transition.
  bool _proceeded = false;
  // Scroll-layout's equivalent one-shot finish guard.
  bool _scrollFinished = false;

  // Not `final` — reset by _restartQuiz(). Single shared source of truth for
  // both layout modes: index i is question i of the current _shuffled order,
  // regardless of which mode answered/submitted it. A null entry means
  // unanswered; per-page's own answering is always sequential, but scroll
  // mode can leave gaps (any question answerable in any order).
  late int _startTimeMs;
  late int _questionStartMs;
  late List<int?> _selectedByIndex;
  late List<bool> _submittedByIndex;
  // Real per-question elapsed time, recorded only by per-page's _submit() —
  // scroll mode has no clean per-question timing concept (every question is
  // visible at once), so its entries stay null and get an even split of
  // whatever time isn't accounted for by real per-page entries (see
  // _buildResult()).
  late List<int?> _timeMsByIndex;

  // Not `final` — live-reshuffled in place when the shuffle setting changes
  // while this screen is open (see the ref.listen in build()).
  late ShuffledQuiz _shuffled;

  // False only while the async resume-check (loadQuizProgress) is in flight —
  // build() must not touch _shuffled/_startTimeMs until this is true.
  bool _progressLoaded = false;

  bool get _quizHasImages => widget.quiz.questions.any((q) => q.hasImage);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    startSecurityGuard();
    if (widget.isPopup) {
      // Popups are always single-shot — never persisted, never resumable.
      _startTimeMs = DateTime.now().millisecondsSinceEpoch;
      _questionStartMs = _startTimeMs;
      _initFreshShuffle();
      _selectedByIndex = List<int?>.filled(_total, null);
      _submittedByIndex = List<bool>.filled(_total, false);
      _timeMsByIndex = List<int?>.filled(_total, null);
      _progressLoaded = true;
    } else {
      _loadOrInitFresh();
    }
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

  void _initFreshShuffle() {
    final settings = ref.read(quizSettingsProvider);
    _shuffled = ShuffledQuiz(
      widget.quiz,
      shuffleQuestions: settings.shuffleQuestions,
      shuffleOptions: settings.shuffleOptions,
    );
  }

  // Toggling shuffle applies live — everything already answered or currently
  // on screen is frozen in place (see ShuffledQuiz.reshuffleFrom), only
  // not-yet-reached questions/options actually reorder. Freeze policy
  // depends on which mode is active: per-page freezes by position (it's
  // strictly sequential), scroll freezes by submitted-state (any order).
  void _liveReshuffle(QuizSettings settings, QuizLayoutMode mode) {
    final frozen = mode == QuizLayoutMode.perPage
        ? {for (var i = 0; i <= _currentIndex; i++) i}
        : {for (var i = 0; i < _total; i++) if (_submittedByIndex[i]) i};
    setState(() {
      _shuffled = _shuffled.reshuffleFrom(
        frozenDisplayIndices: frozen,
        shuffleQuestions: settings.shuffleQuestions,
        shuffleOptions: settings.shuffleOptions,
      );
    });
  }

  // Abandons any in-progress attempt (including a saved resume row, which
  // would otherwise keep silently reusing its original shuffle order no
  // matter how the setting changes later) and starts over from question 0.
  void _restartQuiz() {
    if (!widget.isPopup) {
      QuizDbService.instance.deleteQuizProgress(widget.quiz.id, widget.lectureId);
    }
    setState(() {
      _currentIndex = 0;
      _advancing = false;
      _scrollFinished = false;
      _startTimeMs = DateTime.now().millisecondsSinceEpoch;
      _questionStartMs = _startTimeMs;
      _initFreshShuffle();
      _selectedByIndex = List<int?>.filled(_total, null);
      _submittedByIndex = List<bool>.filled(_total, false);
      _timeMsByIndex = List<int?>.filled(_total, null);
    });
  }

  Future<void> _loadOrInitFresh() async {
    final saved = await QuizDbService.instance
        .loadQuizProgress(widget.quiz.id, widget.lectureId);

    if (saved == null) {
      _startTimeMs = DateTime.now().millisecondsSinceEpoch;
      _questionStartMs = _startTimeMs;
      _initFreshShuffle();
      _selectedByIndex = List<int?>.filled(_total, null);
      _submittedByIndex = List<bool>.filled(_total, false);
      _timeMsByIndex = List<int?>.filled(_total, null);
    } else {
      // The persisted shape is mode-agnostic (a flat per-question array), so
      // it hydrates the same regardless of which mode last saved it — only
      // currentIndex is per-page-specific, restored only when that's what
      // was active (ignored on a scroll-layout resume, matching the
      // pre-existing contract).
      _startTimeMs = saved.startTimeMs;
      _questionStartMs = DateTime.now().millisecondsSinceEpoch;
      _shuffled = ShuffledQuiz.fromSavedOrder(
        widget.quiz,
        questionOrder: saved.questionOrder,
        optionOrders: saved.optionOrders,
      );
      _selectedByIndex = List<int?>.generate(_total,
          (i) => i < saved.answersByIndex.length ? saved.answersByIndex[i] : null);
      _submittedByIndex =
          List<bool>.generate(_total, (i) => _selectedByIndex[i] != null);
      _timeMsByIndex = List<int?>.generate(
          _total, (i) => i < saved.timesByIndex.length ? saved.timesByIndex[i] : null);
      _currentIndex =
          saved.layoutMode == QuizLayoutMode.perPage ? saved.currentIndex : 0;
    }

    if (!mounted) return;
    setState(() => _progressLoaded = true);
  }

  Future<void> _persistProgress() async {
    final mode = ref.read(quizSettingsProvider).layoutMode;
    await QuizDbService.instance.saveQuizProgress(QuizProgressRow(
      quizId: widget.quiz.id,
      lectureId: widget.lectureId,
      videoId: widget.videoId,
      layoutMode: mode,
      questionOrder: _shuffled.questionOrder,
      optionOrders: _shuffled.optionOrdersForPersistence,
      answersByIndex: List<int?>.from(_selectedByIndex),
      timesByIndex: List<int?>.from(_timeMsByIndex),
      currentIndex: mode == QuizLayoutMode.perPage ? _currentIndex : 0,
      startTimeMs: _startTimeMs,
    ));
  }

  QuizQuestion get _question => _shuffled.questionAt(_currentIndex);
  int get _total => _shuffled.length;
  bool get _isLast => _currentIndex == _total - 1;

  // _selectedByIndex/_timeMsByIndex are recorded against display order (what
  // the student actually saw and answered). QuizAttemptResult zips
  // quiz.questions[i] with selectedIndices[i] positionally (see
  // quiz_attempt_result.dart), so the Quiz handed to it must have its
  // questions in that same display order — widget.quiz's original order
  // would silently mismatch once shuffling is enabled. When shuffle is off
  // this is value-identical to widget.quiz.
  Quiz get _displayOrderQuiz => Quiz(
        id: widget.quiz.id,
        courseId: widget.quiz.courseId,
        videoIds: widget.quiz.videoIds,
        title: widget.quiz.title,
        questions: List.generate(_total, (i) => _shuffled.questionAt(i)),
        triggerType: widget.quiz.triggerType,
        triggerAtSecond: widget.quiz.triggerAtSecond,
        questionDirection: widget.quiz.questionDirection,
        explanationDirection: widget.quiz.explanationDirection,
        isGeneralQuiz: widget.quiz.isGeneralQuiz,
        exportAllowed: widget.quiz.exportAllowed,
        isPersonalQuiz: widget.quiz.isPersonalQuiz,
      );

  // Shared by both layout modes — writes go through here so per-index state
  // stays the single source of truth regardless of which mode is displaying.
  void _selectOption(int index, int option) {
    if (_submittedByIndex[index]) return;
    setState(() => _selectedByIndex[index] = option);
  }

  Future<void> _submit() async {
    if (_selectedByIndex[_currentIndex] == null ||
        _submittedByIndex[_currentIndex] ||
        _advancing) {
      return;
    }
    setState(() => _submittedByIndex[_currentIndex] = true);

    _timeMsByIndex[_currentIndex] =
        DateTime.now().millisecondsSinceEpoch - _questionStartMs;
    _proceeded = false;

    if (!widget.isPopup) _persistProgress(); // fire-and-forget

    setState(() => _advancing = true);
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    _proceed();
  }

  // Finalizes the quiz (last question) or advances to the next unanswered
  // question. Runs either from _submit()'s delay or from an explicit
  // swipe/arrow "next" while that delay is still pending — _proceeded
  // ensures only one of those two triggers actually performs the transition.
  void _proceed() {
    if (_proceeded) return;
    _proceeded = true;
    if (_isLast) {
      if (!widget.isPopup) {
        QuizDbService.instance
            .deleteQuizProgress(widget.quiz.id, widget.lectureId);
      }
      context.replace('/quiz-result', extra: _buildResult());
    } else {
      setState(() {
        _currentIndex++;
        _advancing = false;
        _questionStartMs = DateTime.now().millisecondsSinceEpoch;
      });
    }
  }

  void _submitScrollQuestion(int index) {
    if (_selectedByIndex[index] == null || _submittedByIndex[index]) return;
    setState(() => _submittedByIndex[index] = true);
    if (!widget.isPopup) _persistProgress(); // fire-and-forget
    _maybeFinishScroll();
  }

  void _maybeFinishScroll() {
    if (_scrollFinished || !_submittedByIndex.every((s) => s)) return;
    _scrollFinished = true;
    if (!widget.isPopup) {
      QuizDbService.instance.deleteQuizProgress(widget.quiz.id, widget.lectureId);
    }
    context.replace('/quiz-result', extra: _buildResult());
  }

  // Real per-question times (per-page's _submit()) are used as-is; any
  // question submitted via scroll mode (no per-question timing there) gets
  // an even split of whatever total time isn't accounted for by real
  // entries — the same fallback scroll-only sessions always used, now
  // applied per-entry instead of uniformly so a mixed-mode session doesn't
  // lose the real timing it does have.
  QuizAttemptResult _buildResult() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final totalMs = now - _startTimeMs;
    final timed = _timeMsByIndex.whereType<int>().toList();
    final untimedCount = _total - timed.length;
    final fallbackMs = untimedCount == 0
        ? 0
        : (totalMs - timed.fold<int>(0, (a, b) => a + b)) ~/ untimedCount;
    return QuizAttemptResult(
      quiz: _displayOrderQuiz,
      lectureId: widget.lectureId,
      videoId: widget.videoId,
      selectedIndices: List.generate(_total, (i) => _selectedByIndex[i]!),
      questionTimesMs:
          List.generate(_total, (i) => _timeMsByIndex[i] ?? fallbackMs),
      totalTimeMs: totalMs,
      isPopupSource: widget.isPopup,
    );
  }

  // Pure navigation between 0 and the answered frontier — never grades or
  // records anything. Questions at or past the frontier (unanswered) show a
  // blank slate; questions behind it show their already-recorded answer
  // read-only (no re-grading, no re-recording). The shared per-index arrays
  // already hold each question's own state, so this only needs to move
  // _currentIndex — nothing to copy into scalar fields anymore.
  void _viewQuestion(int index) {
    if (index < 0 || index > _answeredFrontier || index >= _total) return;
    if (_advancing) return;
    setState(() => _currentIndex = index);
  }

  void _handleSwipeNext() {
    if (_advancing) {
      _proceed(); // mid-flight after a fresh submit — skip the rest of the wait
      return;
    }
    _viewQuestion(_currentIndex + 1);
  }

  void _handleSwipePrevious() => _viewQuestion(_currentIndex - 1);

  @override
  Widget build(BuildContext context) {
    if (!_progressLoaded) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(
          child: CircularProgressIndicator(color: AppTheme.primary),
        ),
      );
    }

    final settings = ref.watch(quizSettingsProvider);
    final layoutMode = settings.layoutMode;

    // Reacts regardless of which mode is active now that _shuffled is the
    // single shared copy — reads next.layoutMode (not the closed-over
    // layoutMode local) so the freeze policy always matches whichever mode
    // is actually current when the callback fires.
    ref.listen<QuizSettings>(quizSettingsProvider, (previous, next) {
      if (previous == null) return;
      if (previous.shuffleQuestions != next.shuffleQuestions ||
          previous.shuffleOptions != next.shuffleOptions) {
        _liveReshuffle(next, next.layoutMode);
      }
    });

    // Only spin up the shelf server if some question actually has an image —
    // most quizzes are text-only and shouldn't pay for it. Scroll-layout
    // mode handles its own image loading internally (all questions visible
    // at once, not just "the current one"). Personal quizzes never need a
    // shelf server at all — their images are plain local files.
    if (_quizHasImages && layoutMode == QuizLayoutMode.perPage) {
      if (widget.quiz.isPersonalQuiz) {
        final imageId = _question.imageId;
        if (imageId.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => loadPersonalImageIfNeeded(widget.quiz.id, imageId));
        }
      } else {
        final serverAsync = ref.watch(videoServerProvider(VideoPlaybackArgs(
          lectureId: widget.lectureId,
          videoId: '',
          watermarkEnabled: false,
        )));
        serverAsync.whenData((server) {
          final imageId = _question.imageId;
          if (imageId.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) =>
                loadImageIfNeeded(widget.lectureId, imageId, server.port,
                    server.sessionToken));
          }
        });
      }
    }
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        foregroundColor: Colors.white,
        title: Text(
          widget.quiz.title,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (!widget.isPopup)
            IconButton(
              icon: const Icon(Icons.restart_alt_rounded, color: Colors.white70),
              tooltip: 'Restart quiz',
              onPressed: _restartQuiz,
            ),
          IconButton(
            icon: const Icon(Icons.tune_rounded, color: Colors.white70),
            tooltip: 'Quiz settings',
            onPressed: () => showQuizSettingsSheet(context),
          ),
          if (layoutMode == QuizLayoutMode.perPage)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_currentIndex + 1} / $_total',
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
      body: SecurityGuardGate(
        child: layoutMode == QuizLayoutMode.scrollAll
          ? QuizScrollLayout(
              quiz: widget.quiz,
              shuffled: _shuffled,
              lectureId: widget.lectureId,
              videoId: widget.videoId,
              selectedByIndex: _selectedByIndex,
              submittedByIndex: _submittedByIndex,
              onSelectOption: _selectOption,
              onSubmitQuestion: _submitScrollQuestion,
            )
          : Column(
              children: [
                LinearProgressIndicator(
                  value: (_currentIndex + 1) / _total,
                  backgroundColor: Colors.white12,
                  color: AppTheme.primary,
                  minHeight: 3,
                ),
                Expanded(
                  child: QuizNavGestureWrapper(
                    enabled: settings.swipeNavigationEnabled,
                    onNext: _handleSwipeNext,
                    onPrevious: _handleSwipePrevious,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          QuizQuestionBody(
                            quiz: widget.quiz,
                            question: _question,
                            selectedOption: _selectedByIndex[_currentIndex],
                            submitted: _submittedByIndex[_currentIndex],
                            onSelectOption: _submittedByIndex[_currentIndex]
                                ? null
                                : (i) => _selectOption(_currentIndex, i),
                            courseId: widget.quiz.courseId,
                            lectureId: widget.lectureId,
                            imageBytes: cachedImage(
                                widget.quiz.isPersonalQuiz
                                    ? widget.quiz.id
                                    : widget.lectureId,
                                _question.imageId),
                          ),
                          const SizedBox(height: 32),
                          _buildSubmitButton(),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  // First not-yet-submitted index, or _total if every question is submitted.
  // Generalizes the old "_answers.length" contiguous-count concept to a
  // shared store that scroll mode can leave gaps in.
  int get _answeredFrontier {
    final idx = _submittedByIndex.indexWhere((s) => !s);
    return idx == -1 ? _total : idx;
  }

  bool get _isReviewingHistory => _currentIndex < _answeredFrontier;

  Widget _buildSubmitButton() {
    final selected = _selectedByIndex[_currentIndex];
    final submitted = _submittedByIndex[_currentIndex];
    final canSubmit = selected != null && !submitted;
    final label = !submitted
        ? 'Submit'
        : _isReviewingHistory
            ? 'Already answered — swipe to continue'
            : _advancing
                ? (_isLast ? 'Loading results...' : 'Next...')
                : (_isLast ? 'Finishing...' : 'Next Question');

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: canSubmit ? _submit : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.white12,
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
        child: _advancing
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
      ),
    );
  }
}
