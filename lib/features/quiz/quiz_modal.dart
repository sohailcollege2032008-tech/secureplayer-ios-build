import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/quiz.dart';
import 'quiz_nav_gesture_wrapper.dart';
import 'quiz_provider.dart';
import 'quiz_settings_provider.dart';
import 'quiz_settings_screen.dart';
import 'quiz_shuffle.dart';
import '../../app/theme.dart';

class QuizModal extends ConsumerStatefulWidget {
  const QuizModal({
    super.key,
    required this.quiz,
    required this.courseId,
  });

  final Quiz quiz;
  final String courseId;

  @override
  ConsumerState<QuizModal> createState() => _QuizModalState();
}

class _QuizModalState extends ConsumerState<QuizModal> {
  int _currentQuestionIndex = 0;
  int? _selectedOption;
  bool _submitted = false;

  late final ShuffledQuiz _shuffled;

  @override
  void initState() {
    super.initState();
    // Decided once per quiz-taking session — see quiz_screen.dart for why.
    final settings = ref.read(quizSettingsProvider);
    _shuffled = ShuffledQuiz(
      widget.quiz,
      shuffleQuestions: settings.shuffleQuestions,
      shuffleOptions: settings.shuffleOptions,
    );
  }

  final List<int> _answerHistory = [];

  QuizQuestion get _currentQuestion =>
      _shuffled.questionAt(_currentQuestionIndex);
  bool get _isLastQuestion =>
      _currentQuestionIndex == widget.quiz.questions.length - 1;
  bool get _isReviewingHistory =>
      _currentQuestionIndex < _answerHistory.length - 1;

  Future<void> _submit() async {
    if (_selectedOption == null) return;

    setState(() => _submitted = true);
    _answerHistory.add(_selectedOption!);

    if (_isLastQuestion) {
      // Save the first question's answer (primary result)
      await ref.read(quizResultProvider(widget.courseId).notifier).saveResult(
            widget.quiz.id,
            _selectedOption!,
            widget.quiz,
          );
    }
  }

  void _next() {
    if (_isLastQuestion) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _currentQuestionIndex++;
        _selectedOption = null;
        _submitted = false;
      });
    }
  }

  // Pure navigation into already-answered history — shows the recorded
  // answer read-only, never re-grades or re-records. Reaching the frontier
  // (the question just answered, not yet advanced past) falls through to
  // _next() via _advanceOrReview below.
  void _viewQuestion(int index) {
    if (index < 0 || index > _answerHistory.length) return;
    if (index >= widget.quiz.questions.length) return;
    setState(() {
      _currentQuestionIndex = index;
      if (index < _answerHistory.length) {
        _selectedOption = _answerHistory[index];
        _submitted = true;
      } else {
        _selectedOption = null;
        _submitted = false;
      }
    });
  }

  void _advanceOrReview() {
    if (_currentQuestionIndex < _answerHistory.length - 1) {
      _viewQuestion(_currentQuestionIndex + 1);
    } else {
      _next();
    }
  }

  void _handleSwipeNext() {
    if (!_submitted) return; // must select + submit before moving forward
    _advanceOrReview();
  }

  void _handleSwipePrevious() => _viewQuestion(_currentQuestionIndex - 1);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Dialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: QuizNavGestureWrapper(
          enabled: ref.watch(quizSettingsProvider).swipeNavigationEnabled,
          onNext: _handleSwipeNext,
          onPrevious: _handleSwipePrevious,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 20),
                _buildQuestion(),
                const SizedBox(height: 16),
                ..._buildOptions(),
                const SizedBox(height: 20),
                if (_submitted) _buildFeedback(),
                if (_submitted) const SizedBox(height: 16),
                _buildActionButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const Icon(Icons.quiz_rounded, color: AppTheme.primary, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            widget.quiz.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (widget.quiz.questions.length > 1)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '${_currentQuestionIndex + 1}/${widget.quiz.questions.length}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ),
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => showQuizSettingsSheet(context),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.tune_rounded, color: Colors.white54, size: 18),
          ),
        ),
      ],
    );
  }

  Widget _buildQuestion() {
    return Text(
      _currentQuestion.text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        height: 1.5,
      ),
    );
  }

  List<Widget> _buildOptions() {
    return List.generate(_currentQuestion.options.length, (i) {
      Color? bgColor;
      Color borderColor = Colors.white12;
      Color textColor = Colors.white70;

      if (_submitted) {
        if (i == _currentQuestion.correctIndex) {
          bgColor = Colors.green.withValues(alpha: 0.15);
          borderColor = Colors.greenAccent;
          textColor = Colors.greenAccent;
        } else if (i == _selectedOption) {
          bgColor = Colors.red.withValues(alpha: 0.12);
          borderColor = Colors.redAccent;
          textColor = Colors.redAccent;
        }
      } else if (i == _selectedOption) {
        bgColor = AppTheme.primary.withValues(alpha: 0.15);
        borderColor = AppTheme.primary;
        textColor = Colors.white;
      }

      return GestureDetector(
        onTap: _submitted ? null : () => setState(() => _selectedOption = i),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor ?? Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Text(
                String.fromCharCode(65 + i), // A, B, C, D
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _currentQuestion.options[i],
                  style: TextStyle(color: textColor, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildFeedback() {
    final isCorrect = _selectedOption == _currentQuestion.correctIndex;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCorrect
            ? Colors.green.withValues(alpha: 0.1)
            : Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
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
                isCorrect ? Icons.check_circle : Icons.info_outline,
                color: isCorrect ? Colors.greenAccent : Colors.orangeAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                isCorrect ? 'Correct!' : 'Incorrect',
                style: TextStyle(
                  color: isCorrect ? Colors.greenAccent : Colors.orangeAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          if (_currentQuestion.explanation.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _currentQuestion.explanation,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    final label = !_submitted
        ? 'Submit'
        : _isReviewingHistory
            ? 'Already answered — swipe to continue'
            : _isLastQuestion
                ? 'Continue Watching'
                : 'Next Question';

    final canSubmit = _selectedOption != null && !_submitted;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _submitted ? _advanceOrReview : (canSubmit ? _submit : null),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
    );
  }
}
