import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/quiz_db_service.dart';
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

/// A plain browsable repository of every starred question across the picked
/// sources — always shown revealed (correct answer + explanation visible
/// immediately), free swipe/arrow navigation, no rating, no SRS writes, no
/// due-date logic at all. Starring is the only filter; un-starring here
/// removes the question from this list immediately.
class StarredBrowseScreen extends ConsumerStatefulWidget {
  const StarredBrowseScreen({super.key, required this.lectureIds});

  final List<String> lectureIds;

  @override
  ConsumerState<StarredBrowseScreen> createState() =>
      _StarredBrowseScreenState();
}

class _StarredBrowseScreenState extends ConsumerState<StarredBrowseScreen>
    with
        EncryptedImageCacheMixin<StarredBrowseScreen>,
        WidgetsBindingObserver,
        SecurityRuntimeGuardMixin {
  bool _loading = true;
  List<ReviewQuestion> _deck = [];
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    startSecurityGuard();
    _load();
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

  Future<void> _load() async {
    final quizzesByLecture = {
      for (final id in widget.lectureIds) id: await quizzesForScopeId(ref, id),
    };
    final starredKeys =
        await QuizDbService.instance.starredKeysForLectures(widget.lectureIds);
    final deck = buildReviewDeck(
      quizzesByLecture: quizzesByLecture,
      srsRows: const {},
      now: DateTime.now(),
      filterMode: ReviewFilterMode.starredOnly,
      starredKeys: starredKeys,
    );
    if (!mounted) return;
    setState(() {
      _deck = deck.sessionList(practice: true);
      _loading = false;
    });
  }

  ReviewQuestion get _current => _deck[_index];

  void _goNext() {
    if (_index + 1 < _deck.length) setState(() => _index++);
  }

  void _goPrevious() {
    if (_index > 0) setState(() => _index--);
  }

  Future<void> _unstar(ReviewQuestion entry) async {
    await ref.read(starredProvider(entry.courseId).notifier).toggle(
          questionId: entry.question.id,
          quizId: entry.quizId,
          lectureId: entry.lectureId,
        );
    if (!mounted) return;
    setState(() {
      _deck.removeAt(_index);
      if (_index >= _deck.length && _index > 0) _index--;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D0D),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
        ),
      );
    }

    if (_deck.isEmpty) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          foregroundColor: Colors.white,
          title: const Text('Starred Questions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        body: const Center(
          child: Text(
            'No starred questions here.',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    final entry = _current;
    final styles = QuizTextStyles.forSettings(ref.watch(quizSettingsProvider));
    final isStarred = ref
        .watch(starredProvider(entry.courseId))
        .isStarred(entry.question.id);

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

    final settings = ref.watch(quizSettingsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: const Text('Starred Questions',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(
              isStarred ? Icons.star_rounded : Icons.star_border_rounded,
              color: isStarred ? Colors.amber : Colors.white70,
            ),
            tooltip: isStarred ? 'Unstar' : 'Star',
            onPressed: () => _unstar(entry),
          ),
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
        child: QuizNavGestureWrapper(
          enabled: settings.swipeNavigationEnabled,
          onNext: _goNext,
          onPrevious: _goPrevious,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                _buildQuestion(entry, styles),
                const SizedBox(height: 24),
                ..._buildOptions(entry, styles),
                const SizedBox(height: 20),
                _buildExplanation(entry, styles),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuestion(ReviewQuestion entry, QuizTextStyles styles) {
    return QuestionTextWithImage(
      text: entry.question.text,
      hasImage: entry.question.hasImage,
      imageBytes: cachedImage(
          entry.isPersonalQuiz ? entry.quizId : entry.lectureId,
          entry.question.imageId),
      textStyle: styles.questionStyle,
    );
  }

  // Always revealed — no selection concept, the correct option is always
  // highlighted. This is a reference view, not a quiz.
  List<Widget> _buildOptions(ReviewQuestion entry, QuizTextStyles styles) {
    final question = entry.question;
    return List.generate(question.options.length, (i) {
      final isCorrect = i == question.correctIndex;
      final bgColor = isCorrect
          ? Colors.green.withValues(alpha: 0.15)
          : Colors.white.withValues(alpha: 0.04);
      final borderColor = isCorrect ? Colors.greenAccent : Colors.white12;
      final textColor = isCorrect ? Colors.greenAccent : Colors.white70;

      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: bgColor,
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
                color: isCorrect
                    ? Colors.green.withValues(alpha: 0.3)
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
      );
    });
  }

  Widget _buildExplanation(ReviewQuestion entry, QuizTextStyles styles) {
    if (entry.question.explanation.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        entry.question.explanation,
        style: styles.explanationStyle,
      ),
    );
  }
}
