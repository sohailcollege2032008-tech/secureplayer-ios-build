import 'dart:convert';

import 'personal_quiz_draft_state.dart';

/// Parses the same teacher-facing quiz-import JSON format Studio's
/// `AddQuizDialog`/`parseQuizBlocksFromJson` accept
/// (studio_flutter/lib/features/lecture_editor/lecture_editor_state.dart) —
/// this is "the same JSON system the teacher uses" students get for
/// personal quizzes.
///
/// Accepts either the array form Studio produces
/// (`[{title, questions:[...]}, ...]`) or a single quiz object
/// (`{title, questions:[...]}`) — a personal quiz draft holds exactly one
/// quiz, so if an array has more than one entry, only the first is used and
/// [multipleQuizzesInArray] is set on the result so the caller can warn.
///
/// Throws [FormatException] on malformed input, same as the Studio parser.
class ParsedPersonalQuiz {
  const ParsedPersonalQuiz({
    required this.title,
    required this.questions,
    required this.questionDirection,
    required this.explanationDirection,
    required this.multipleQuizzesInArray,
  });

  final String? title;
  final List<PersonalQuizQuestionDraft> questions;
  final String? questionDirection;
  final String? explanationDirection;
  final bool multipleQuizzesInArray;
}

ParsedPersonalQuiz parsePersonalQuizFromJson(String raw) {
  final decoded = jsonDecode(raw);

  Map<String, dynamic> quizMap;
  var multiple = false;
  if (decoded is List) {
    if (decoded.isEmpty) {
      throw const FormatException('The JSON array is empty.');
    }
    if (decoded.first is! Map) {
      throw const FormatException('Each quiz must be an object.');
    }
    quizMap = (decoded.first as Map).cast<String, dynamic>();
    multiple = decoded.length > 1;
  } else if (decoded is Map) {
    quizMap = decoded.cast<String, dynamic>();
  } else {
    throw const FormatException(
      'Top-level JSON must be a quiz object or an array of quizzes.',
    );
  }

  final questions = <PersonalQuizQuestionDraft>[];
  for (final q in (quizMap['questions'] as List? ?? [])) {
    if (q is! Map) {
      throw const FormatException('Each question must be an object.');
    }
    final qm = q.cast<String, dynamic>();
    questions.add(
      PersonalQuizQuestionDraft(
        id: qm['id'] as String? ?? shortId('q'),
        text: qm['text'] as String? ?? '',
        options: (qm['options'] as List? ?? []).cast<String>(),
        correctIndex: (qm['correct_index'] as num?)?.toInt() ?? 0,
        explanation: qm['explanation'] as String? ?? '',
        questionDirectionOverride:
            qm['question_direction_override'] as String?,
        explanationDirectionOverride:
            qm['explanation_direction_override'] as String?,
      ),
    );
  }

  return ParsedPersonalQuiz(
    title: quizMap['title'] as String?,
    questions: questions,
    questionDirection: quizMap['question_direction'] as String?,
    explanationDirection: quizMap['explanation_direction'] as String?,
    multipleQuizzesInArray: multiple,
  );
}
