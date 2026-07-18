import 'dart:convert';

import 'quiz_settings.dart';

/// A saved in-progress quiz attempt — lets a student resume exactly where
/// they left off, including the exact shuffle order (if shuffle was on),
/// so previously-given answers still attach to the correct questions.
class QuizProgressRow {
  const QuizProgressRow({
    required this.quizId,
    required this.lectureId,
    this.videoId,
    required this.layoutMode,
    required this.questionOrder,
    required this.optionOrders,
    required this.answersByIndex,
    required this.timesByIndex,
    required this.currentIndex,
    required this.startTimeMs,
  });

  final String quizId;
  final String lectureId;
  final String? videoId;
  final QuizLayoutMode layoutMode;
  final List<int> questionOrder;
  final List<List<int>> optionOrders;
  // Sparse, display-index-keyed — null means unanswered at that position.
  final List<int?> answersByIndex;
  final List<int?> timesByIndex;
  // Meaningful for the per-page layout only; ignored on scroll-layout resume.
  final int currentIndex;
  final int startTimeMs;

  factory QuizProgressRow.fromMap(Map<String, dynamic> m) => QuizProgressRow(
        quizId: m['quiz_id'] as String,
        lectureId: m['lecture_id'] as String,
        videoId: m['video_id'] as String?,
        layoutMode: QuizLayoutMode.values.firstWhere(
          (e) => e.name == m['layout_mode'],
          orElse: () => QuizLayoutMode.perPage,
        ),
        questionOrder:
            List<int>.from(jsonDecode(m['question_order'] as String) as List),
        optionOrders:
            (jsonDecode(m['option_orders'] as String) as List)
                .map((e) => List<int>.from(e as List))
                .toList(),
        answersByIndex: (jsonDecode(m['answers_by_index'] as String) as List)
            .map((e) => e as int?)
            .toList(),
        timesByIndex: (jsonDecode(m['times_by_index'] as String) as List)
            .map((e) => e as int?)
            .toList(),
        currentIndex: m['current_index'] as int,
        startTimeMs: m['start_time_ms'] as int,
      );

  Map<String, dynamic> toMap() => {
        'quiz_id': quizId,
        'lecture_id': lectureId,
        'video_id': videoId,
        'layout_mode': layoutMode.name,
        'question_order': jsonEncode(questionOrder),
        'option_orders': jsonEncode(optionOrders),
        'answers_by_index': jsonEncode(answersByIndex),
        'times_by_index': jsonEncode(timesByIndex),
        'current_index': currentIndex,
        'start_time_ms': startTimeMs,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };
}
