import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/quiz.dart';
import '../../local_server/server_provider.dart';
import '../../shared/encrypted_image_cache_mixin.dart';
import 'quiz_question_body.dart';
import 'quiz_shuffle.dart';
import '../../app/theme.dart';

/// All questions in one scrollable page, each in its own box that expands
/// once answered to reveal the explanation — the alternative to
/// quiz_screen.dart's default one-question-per-page layout. A dumb renderer
/// (same pattern as QuizQuestionBody): all answer/submitted state and
/// persistence lives in quiz_screen.dart's _QuizScreenState, the single
/// shared source of truth across both layout modes — this widget only
/// reads/writes through the constructor-supplied values and callbacks.
class QuizScrollLayout extends ConsumerStatefulWidget {
  const QuizScrollLayout({
    super.key,
    required this.quiz,
    required this.shuffled,
    required this.lectureId,
    required this.selectedByIndex,
    required this.submittedByIndex,
    required this.onSelectOption,
    required this.onSubmitQuestion,
    this.videoId,
  });

  final Quiz quiz;
  final ShuffledQuiz shuffled;
  final String lectureId;
  final String? videoId;
  final List<int?> selectedByIndex;
  final List<bool> submittedByIndex;
  final void Function(int index, int optionIndex) onSelectOption;
  final void Function(int index) onSubmitQuestion;

  @override
  ConsumerState<QuizScrollLayout> createState() => _QuizScrollLayoutState();
}

class _QuizScrollLayoutState extends ConsumerState<QuizScrollLayout>
    with EncryptedImageCacheMixin<QuizScrollLayout> {
  int get _total => widget.shuffled.length;

  @override
  Widget build(BuildContext context) {
    final hasImages = widget.quiz.questions.any((q) => q.hasImage);
    if (hasImages) {
      if (widget.quiz.isPersonalQuiz) {
        for (var i = 0; i < _total; i++) {
          final imageId = widget.shuffled.questionAt(i).imageId;
          if (imageId.isEmpty) continue;
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
          for (var i = 0; i < _total; i++) {
            final imageId = widget.shuffled.questionAt(i).imageId;
            if (imageId.isEmpty) continue;
            WidgetsBinding.instance.addPostFrameCallback((_) =>
                loadImageIfNeeded(widget.lectureId, imageId, server.port,
                    server.sessionToken));
          }
        });
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _total,
      itemBuilder: (context, i) {
        final question = widget.shuffled.questionAt(i);
        return _ExpandingQuestionCard(
          index: i,
          total: _total,
          quiz: widget.quiz,
          question: question,
          selectedOption: widget.selectedByIndex[i],
          submitted: widget.submittedByIndex[i],
          imageBytes: cachedImage(
              widget.quiz.isPersonalQuiz ? widget.quiz.id : widget.lectureId,
              question.imageId),
          onSelectOption: (opt) => widget.onSelectOption(i, opt),
          onSubmit: () => widget.onSubmitQuestion(i),
          courseId: widget.quiz.courseId,
          lectureId: widget.lectureId,
        );
      },
    );
  }
}

class _ExpandingQuestionCard extends StatelessWidget {
  const _ExpandingQuestionCard({
    required this.index,
    required this.total,
    required this.quiz,
    required this.question,
    required this.selectedOption,
    required this.submitted,
    required this.imageBytes,
    required this.onSelectOption,
    required this.onSubmit,
    required this.courseId,
    required this.lectureId,
  });

  final int index;
  final int total;
  final Quiz quiz;
  final QuizQuestion question;
  final int? selectedOption;
  final bool submitted;
  final Uint8List? imageBytes;
  final ValueChanged<int> onSelectOption;
  final VoidCallback onSubmit;
  final String courseId;
  final String lectureId;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.primary.withValues(alpha: 0.2),
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Question ${index + 1} of $total',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            QuizQuestionBody(
              quiz: quiz,
              question: question,
              selectedOption: selectedOption,
              submitted: submitted,
              onSelectOption: submitted ? null : onSelectOption,
              courseId: courseId,
              lectureId: lectureId,
              imageBytes: imageBytes,
            ),
            if (!submitted) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: selectedOption != null ? onSubmit : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white12,
                    disabledForegroundColor: Colors.white38,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape:
                        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  child: const Text('Submit',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
