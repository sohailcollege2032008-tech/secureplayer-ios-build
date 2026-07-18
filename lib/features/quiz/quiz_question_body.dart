import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/quiz.dart';
import '../../shared/widgets/question_image_block.dart';
import 'quiz_provider.dart';
import 'quiz_settings_provider.dart';
import 'quiz_text_styles.dart';

/// Renders one question: text (+ optional image), options, star-while-solving,
/// and — once submitted — correct/incorrect feedback with explanation. Shared
/// by quiz_screen.dart's per-page and scrollable (quiz_scroll_layout.dart)
/// layouts so question rendering, font size, and direction live in one place.
class QuizQuestionBody extends ConsumerWidget {
  const QuizQuestionBody({
    super.key,
    required this.quiz,
    required this.question,
    required this.selectedOption,
    required this.submitted,
    required this.onSelectOption,
    required this.courseId,
    this.lectureId = '',
    this.imageBytes,
    this.showStar = true,
  });

  final Quiz quiz;
  final QuizQuestion question;
  final int? selectedOption;
  final bool submitted;
  // Null when locked — already submitted, or read-only history review.
  final ValueChanged<int>? onSelectOption;
  final String courseId;
  final String lectureId;
  final Uint8List? imageBytes;
  final bool showStar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = QuizTextStyles.forSettings(ref.watch(quizSettingsProvider));
    final questionDir = quiz.effectiveQuestionDirection(question);
    final explanationDir = quiz.effectiveExplanationDirection(question);
    final starred = showStar &&
        ref.watch(starredProvider(courseId)).isStarred(question.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Directionality(
                textDirection: questionDir,
                child: QuestionTextWithImage(
                  text: question.text,
                  hasImage: question.hasImage,
                  imageBytes: imageBytes,
                  textStyle: styles.questionStyle,
                ),
              ),
            ),
            if (showStar)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  starred ? Icons.star_rounded : Icons.star_border_rounded,
                  color: starred ? Colors.amber : Colors.white38,
                ),
                tooltip: starred ? 'Unstar' : 'Star for review',
                onPressed: () =>
                    ref.read(starredProvider(courseId).notifier).toggle(
                          questionId: question.id,
                          quizId: quiz.id,
                          lectureId: lectureId,
                        ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        ...List.generate(
          question.options.length,
          (i) => _OptionTile(
            index: i,
            text: question.options[i],
            style: styles.optionStyle,
            isSelected: selectedOption == i,
            isCorrect: i == question.correctIndex,
            submitted: submitted,
            onTap: onSelectOption == null ? null : () => onSelectOption!(i),
          ),
        ),
        if (submitted) ...[
          const SizedBox(height: 16),
          Directionality(
            textDirection: explanationDir,
            child: _FeedbackBox(
              isCorrect: selectedOption == question.correctIndex,
              explanation: question.explanation,
              titleStyle: styles.feedbackTitleStyle,
              explanationStyle: styles.explanationStyle,
            ),
          ),
        ],
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.index,
    required this.text,
    required this.style,
    required this.isSelected,
    required this.isCorrect,
    required this.submitted,
    required this.onTap,
  });

  final int index;
  final String text;
  final TextStyle style;
  final bool isSelected;
  final bool isCorrect;
  final bool submitted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Color? bgColor;
    Color borderColor = Colors.white12;
    Color textColor = Colors.white70;

    if (submitted) {
      if (isCorrect) {
        bgColor = Colors.green.withValues(alpha: 0.15);
        borderColor = Colors.greenAccent;
        textColor = Colors.greenAccent;
      } else if (isSelected) {
        bgColor = Colors.red.withValues(alpha: 0.12);
        borderColor = Colors.redAccent;
        textColor = Colors.redAccent;
      }
    } else if (isSelected) {
      bgColor = const Color(0xFF6C63FF).withValues(alpha: 0.15);
      borderColor = const Color(0xFF6C63FF);
      textColor = Colors.white;
    }

    return GestureDetector(
      onTap: onTap,
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
                color: submitted && isSelected
                    ? (isCorrect
                        ? Colors.green.withValues(alpha: 0.3)
                        : Colors.red.withValues(alpha: 0.2))
                    : Colors.transparent,
              ),
              child: Center(
                child: Text(
                  String.fromCharCode(65 + index),
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
              child: Text(text, style: style.copyWith(color: textColor)),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedbackBox extends StatelessWidget {
  const _FeedbackBox({
    required this.isCorrect,
    required this.explanation,
    required this.titleStyle,
    required this.explanationStyle,
  });

  final bool isCorrect;
  final String explanation;
  final TextStyle titleStyle;
  final TextStyle explanationStyle;

  @override
  Widget build(BuildContext context) {
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
                style: titleStyle.copyWith(
                  color: isCorrect ? Colors.greenAccent : Colors.orangeAccent,
                ),
              ),
            ],
          ),
          if (explanation.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(explanation, style: explanationStyle),
          ],
        ],
      ),
    );
  }
}
