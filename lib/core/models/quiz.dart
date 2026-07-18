import 'dart:ui' show TextDirection;

class QuizQuestion {
  const QuizQuestion({
    required this.id,
    required this.text,
    required this.options,
    required this.correctIndex,
    required this.explanation,
    this.imageId = '',
    this.questionDirectionOverride,
    this.explanationDirectionOverride,
  });

  final String id;
  final String text;
  final List<String> options;
  final int correctIndex;
  final String explanation;
  // References an encrypted image bundled in the .sec under files/{imageId}.
  // Empty means the question has no image. Never a local/disk path — bytes
  // are fetched in-memory from the shelf server, same as PDFs.
  final String imageId;
  // 'ltr' | 'rtl' | null. Null means inherit the parent Quiz's direction —
  // use Quiz.effectiveQuestionDirection/effectiveExplanationDirection rather
  // than reading these directly.
  final String? questionDirectionOverride;
  final String? explanationDirectionOverride;

  bool get hasImage => imageId.isNotEmpty;

  factory QuizQuestion.fromJson(Map<String, dynamic> json) => QuizQuestion(
        id: json['id'] as String? ?? '',
        text: json['text'] as String,
        options: List<String>.from(json['options'] as List),
        correctIndex: json['correct_index'] as int,
        explanation: json['explanation'] as String? ?? '',
        imageId: json['image_id'] as String? ?? '',
        questionDirectionOverride:
            json['question_direction_override'] as String?,
        explanationDirectionOverride:
            json['explanation_direction_override'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'options': options,
        'correct_index': correctIndex,
        'explanation': explanation,
        if (imageId.isNotEmpty) 'image_id': imageId,
        if (questionDirectionOverride != null)
          'question_direction_override': questionDirectionOverride,
        if (explanationDirectionOverride != null)
          'explanation_direction_override': explanationDirectionOverride,
      };
}

class Quiz {
  const Quiz({
    required this.id,
    required this.courseId,
    required this.videoIds,
    required this.title,
    required this.questions,
    this.triggerType = 'end_of_video',
    this.triggerAtSecond = 0,
    this.questionDirection = 'rtl',
    this.explanationDirection = 'rtl',
    this.isGeneralQuiz = false,
    this.exportAllowed = false,
    this.isPersonalQuiz = false,
  });

  final String id;
  final String courseId;
  final List<String> videoIds; // empty = lecture-level scope
  final String title;
  final List<QuizQuestion> questions;
  final String triggerType;
  final int triggerAtSecond;
  // Quiz-level default direction ('ltr' | 'rtl'); individual questions may
  // override via QuizQuestion.questionDirectionOverride/explanationDirectionOverride.
  final String questionDirection;
  final String explanationDirection;
  // True only for quizzes imported from a standalone .secquiz collection.
  // Both a lecture-wide quiz and a course-level General Quiz have
  // videoIds.isEmpty, so this is the only way to tell them apart — set only
  // by SecImporter.importQuizCollection(), never present in quizzes.json.
  final bool isGeneralQuiz;
  // Combined Anki/PDF export permission set by the teacher in Studio.
  // Defaults false so quizzes.json files built before this field existed
  // stay non-exportable rather than silently becoming extractable.
  final bool exportAllowed;
  // True only for student-authored personal quizzes (never present in
  // quizzes.json) — stamped in-memory by personalQuizzesProvider, same
  // runtime-only-flag pattern as isGeneralQuiz. Personal quizzes skip the
  // exportAllowed gate entirely (the student owns the content) and their
  // question images are plain local files, not shelf-server-fetched.
  final bool isPersonalQuiz;

  // Convenience getters
  String get videoId => videoIds.isNotEmpty ? videoIds.first : '';
  bool get isLectureLevel => videoIds.isEmpty;
  bool get isPopupQuiz => triggerType == 'inline_popup';
  bool appliesToVideo(String vid) => videoIds.isEmpty || videoIds.contains(vid);

  Quiz copyWith({bool? isGeneralQuiz, bool? isPersonalQuiz}) => Quiz(
        id: id,
        courseId: courseId,
        videoIds: videoIds,
        title: title,
        questions: questions,
        triggerType: triggerType,
        triggerAtSecond: triggerAtSecond,
        questionDirection: questionDirection,
        explanationDirection: explanationDirection,
        isGeneralQuiz: isGeneralQuiz ?? this.isGeneralQuiz,
        exportAllowed: exportAllowed,
        isPersonalQuiz: isPersonalQuiz ?? this.isPersonalQuiz,
      );

  TextDirection effectiveQuestionDirection(QuizQuestion q) =>
      _parseDirection(q.questionDirectionOverride ?? questionDirection);
  TextDirection effectiveExplanationDirection(QuizQuestion q) =>
      _parseDirection(q.explanationDirectionOverride ?? explanationDirection);

  static TextDirection _parseDirection(String value) =>
      value == 'ltr' ? TextDirection.ltr : TextDirection.rtl;

  factory Quiz.fromJson(Map<String, dynamic> json) {
    // v2.1: scope.video_ids (list)
    // v2.0: scope.video_id (single string)
    // v1.0: flat video_id field
    final scope = json['scope'] as Map<String, dynamic>?;
    List<String> videoIds;
    if (scope != null) {
      final rawIds = scope['video_ids'];
      if (rawIds is List) {
        videoIds = List<String>.from(rawIds);
      } else {
        final single = scope['video_id'] as String? ?? '';
        videoIds = single.isNotEmpty ? [single] : [];
      }
    } else {
      final single = json['video_id'] as String? ?? '';
      videoIds = single.isNotEmpty ? [single] : [];
    }
    final trigger = json['trigger'] as Map<String, dynamic>?;
    return Quiz(
      id: json['id'] as String,
      courseId: json['course_id'] as String? ?? '',
      videoIds: videoIds,
      title: json['title'] as String? ?? 'Quiz',
      triggerType: trigger?['type'] as String? ?? 'end_of_video',
      triggerAtSecond: (trigger?['at_second'] as int?) ?? 0,
      questionDirection: json['question_direction'] as String? ?? 'rtl',
      explanationDirection: json['explanation_direction'] as String? ?? 'rtl',
      exportAllowed: json['export_allowed'] as bool? ?? false,
      questions: (json['questions'] as List? ?? [])
          .map((q) => QuizQuestion.fromJson(q as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'course_id': courseId,
        'video_ids': videoIds,
        'title': title,
        'question_direction': questionDirection,
        'explanation_direction': explanationDirection,
        'export_allowed': exportAllowed,
        'questions': questions.map((q) => q.toJson()).toList(),
      };
}

class QuizResult {
  const QuizResult({
    required this.quizId,
    required this.selectedIndex,
    required this.isCorrect,
    required this.answeredAt,
    this.isSynced = false,
  });

  final String quizId;
  final int selectedIndex;
  final bool isCorrect;
  final DateTime answeredAt;
  final bool isSynced;

  Map<String, dynamic> toJson() => {
        'quiz_id': quizId,
        'selected_index': selectedIndex,
        'is_correct': isCorrect,
        'answered_at': answeredAt.toIso8601String(),
        'is_synced': isSynced,
      };

  factory QuizResult.fromJson(Map<String, dynamic> json) => QuizResult(
        quizId: json['quiz_id'] as String,
        selectedIndex: json['selected_index'] as int,
        isCorrect: json['is_correct'] as bool,
        answeredAt: DateTime.parse(json['answered_at'] as String),
        isSynced: json['is_synced'] as bool? ?? false,
      );

  QuizResult copyWith({bool? isSynced}) => QuizResult(
        quizId: quizId,
        selectedIndex: selectedIndex,
        isCorrect: isCorrect,
        answeredAt: answeredAt,
        isSynced: isSynced ?? this.isSynced,
      );

  Map<String, dynamic> toFirestore() => {
        'quiz_id': quizId,
        'selected_index': selectedIndex,
        'is_correct': isCorrect,
        'answered_at': answeredAt.toIso8601String(),
      };
}
