import '../../core/models/quiz.dart';

class QuizAttemptResult {
  const QuizAttemptResult({
    required this.quiz,
    required this.lectureId,
    this.videoId,
    required this.selectedIndices,
    required this.questionTimesMs,
    required this.totalTimeMs,
    this.isPopupSource = false,
  });

  final Quiz quiz;
  final String lectureId;
  final String? videoId;
  final List<int> selectedIndices;
  final List<int> questionTimesMs;
  final int totalTimeMs;
  final bool isPopupSource;

  int get correctCount {
    int count = 0;
    for (int i = 0; i < quiz.questions.length; i++) {
      if (i < selectedIndices.length &&
          selectedIndices[i] == quiz.questions[i].correctIndex) {
        count++;
      }
    }
    return count;
  }

  int get totalQuestions => quiz.questions.length;

  double get scorePercent =>
      totalQuestions == 0 ? 0 : correctCount / totalQuestions;

  String get formattedTime {
    final s = totalTimeMs ~/ 1000;
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}
