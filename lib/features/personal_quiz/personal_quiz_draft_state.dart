import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Generates a short, sufficiently-unique id for personal quiz/question
/// drafts — avoids adding a `uuid` dependency (already only a transitive
/// one here) for what only needs to be unique within one student's device.
String shortId(String prefix) {
  final rand = Random();
  final suffix = List.generate(8, (_) => rand.nextInt(36).toRadixString(36))
      .join();
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$suffix';
}

/// One question in a personal-quiz draft. Field-for-field port of Studio's
/// `QuizQuestionDraft` (studio_flutter/lib/features/lecture_editor/
/// lecture_editor_state.dart) — same JSON keys, so
/// personal_quiz_json_import.dart accepts exactly the same paste-JSON shape
/// the teacher-facing AddQuizDialog does.
class PersonalQuizQuestionDraft {
  PersonalQuizQuestionDraft({
    required this.id,
    required this.text,
    required this.options,
    required this.correctIndex,
    this.explanation = '',
    this.imagePath = '',
    this.imageId = '',
    this.questionDirectionOverride,
    this.explanationDirectionOverride,
  });

  final String id;
  final String text;
  final List<String> options;
  final int correctIndex;
  final String explanation;
  // Local file path picked via file_picker, build-time only — never
  // serialized into the finalized quiz.json (mirrors QuizQuestion.imageId's
  // doc comment in core/models/quiz.dart).
  final String imagePath;
  final String imageId;
  final String? questionDirectionOverride;
  final String? explanationDirectionOverride;

  PersonalQuizQuestionDraft copyWith({
    String? text,
    List<String>? options,
    int? correctIndex,
    String? explanation,
    String? imagePath,
    String? imageId,
    String? questionDirectionOverride,
    bool clearQuestionDirectionOverride = false,
    String? explanationDirectionOverride,
    bool clearExplanationDirectionOverride = false,
  }) =>
      PersonalQuizQuestionDraft(
        id: id,
        text: text ?? this.text,
        options: options ?? this.options,
        correctIndex: correctIndex ?? this.correctIndex,
        explanation: explanation ?? this.explanation,
        imagePath: imagePath ?? this.imagePath,
        imageId: imageId ?? this.imageId,
        questionDirectionOverride: clearQuestionDirectionOverride
            ? null
            : (questionDirectionOverride ?? this.questionDirectionOverride),
        explanationDirectionOverride: clearExplanationDirectionOverride
            ? null
            : (explanationDirectionOverride ??
                this.explanationDirectionOverride),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'options': options,
        'correctIndex': correctIndex,
        'explanation': explanation,
        'imagePath': imagePath,
        'imageId': imageId,
        if (questionDirectionOverride != null)
          'questionDirectionOverride': questionDirectionOverride,
        if (explanationDirectionOverride != null)
          'explanationDirectionOverride': explanationDirectionOverride,
      };

  factory PersonalQuizQuestionDraft.fromJson(Map<String, dynamic> j) =>
      PersonalQuizQuestionDraft(
        id: j['id'] as String,
        text: j['text'] as String? ?? '',
        options: (j['options'] as List? ?? []).cast<String>(),
        correctIndex: (j['correctIndex'] as num?)?.toInt() ?? 0,
        explanation: j['explanation'] as String? ?? '',
        imagePath: j['imagePath'] as String? ?? '',
        imageId: j['imageId'] as String? ?? '',
        questionDirectionOverride: j['questionDirectionOverride'] as String?,
        explanationDirectionOverride:
            j['explanationDirectionOverride'] as String?,
      );
}

/// A student-authored quiz in progress. One draft == one personal quiz —
/// unlike Studio's QuizBlock (which lives inside a lecture's list of many
/// quizzes), a personal quiz has no lecture/scope/trigger concept at all, so
/// those fields are simply absent here rather than hidden in the UI.
class PersonalQuizDraft {
  const PersonalQuizDraft({
    required this.id,
    this.title = '',
    this.questions = const [],
    this.questionDirection = 'rtl',
    this.explanationDirection = 'rtl',
  });

  final String id;
  final String title;
  final List<PersonalQuizQuestionDraft> questions;
  final String questionDirection;
  final String explanationDirection;

  PersonalQuizDraft copyWith({
    String? title,
    List<PersonalQuizQuestionDraft>? questions,
    String? questionDirection,
    String? explanationDirection,
  }) =>
      PersonalQuizDraft(
        id: id,
        title: title ?? this.title,
        questions: questions ?? this.questions,
        questionDirection: questionDirection ?? this.questionDirection,
        explanationDirection: explanationDirection ?? this.explanationDirection,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'questionDirection': questionDirection,
        'explanationDirection': explanationDirection,
        'questions': questions.map((q) => q.toJson()).toList(),
      };

  factory PersonalQuizDraft.fromJson(Map<String, dynamic> j) =>
      PersonalQuizDraft(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        questionDirection: j['questionDirection'] as String? ?? 'rtl',
        explanationDirection: j['explanationDirection'] as String? ?? 'rtl',
        questions: (j['questions'] as List? ?? [])
            .map((e) =>
                PersonalQuizQuestionDraft.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Surfaces draft load/save failures to the editor UI — same pattern as
/// Studio's `draftErrorProvider`.
final personalQuizDraftErrorProvider =
    StateProvider.family<String?, String>((ref, draftId) => null);

class PersonalQuizDraftNotifier extends StateNotifier<PersonalQuizDraft> {
  PersonalQuizDraftNotifier(this._ref, String draftId)
      : super(PersonalQuizDraft(id: draftId)) {
    Future.microtask(_loadDraft);
  }

  final Ref _ref;
  Timer? _saveTimer;

  static Future<Directory> _draftsDir() async {
    final dir = await getApplicationSupportDirectory();
    final drafts = Directory('${dir.path}/personal_quiz_drafts');
    if (!drafts.existsSync()) drafts.createSync(recursive: true);
    return drafts;
  }

  static Future<File> _draftFile(String id) async {
    final dir = await _draftsDir();
    return File('${dir.path}/$id.json');
  }

  /// Directory holding this draft's picked-but-not-yet-generated images.
  static Future<Directory> imagesDir(String draftId) async {
    final dir = await _draftsDir();
    final images = Directory('${dir.path}/$draftId/images');
    if (!images.existsSync()) images.createSync(recursive: true);
    return images;
  }

  Future<void> _loadDraft() async {
    try {
      final f = await _draftFile(state.id);
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      if (mounted) super.state = PersonalQuizDraft.fromJson(json);
    } catch (e) {
      if (mounted) {
        _ref.read(personalQuizDraftErrorProvider(state.id).notifier).state =
            'Could not read your saved draft — it opened empty. ($e)';
      }
    }
  }

  @override
  set state(PersonalQuizDraft value) {
    super.state = value;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () async {
      try {
        final f = await _draftFile(value.id);
        f.writeAsStringSync(jsonEncode(value.toJson()));
      } catch (e) {
        if (mounted) {
          _ref.read(personalQuizDraftErrorProvider(value.id).notifier).state =
              'Failed to save your last change — it may not persist. ($e)';
        }
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  /// Deletes the on-disk draft file (and its images dir) — called after a
  /// successful generate, or when the student discards the draft.
  Future<void> deleteDraft() async {
    try {
      final f = await _draftFile(state.id);
      if (await f.exists()) await f.delete();
      final imgDir = await imagesDir(state.id);
      if (await imgDir.exists()) await imgDir.delete(recursive: true);
    } catch (_) {
      // Best effort — a stray draft file isn't worth surfacing an error for.
    }
  }

  void updateTitle(String title) => state = state.copyWith(title: title);

  void updateQuestionDirection(String direction) =>
      state = state.copyWith(questionDirection: direction);

  void updateExplanationDirection(String direction) =>
      state = state.copyWith(explanationDirection: direction);

  void addQuestion() {
    final q = PersonalQuizQuestionDraft(
      id: shortId('q'),
      text: '',
      options: const ['', ''],
      correctIndex: 0,
    );
    state = state.copyWith(questions: [...state.questions, q]);
  }

  void removeQuestion(String questionId) {
    state = state.copyWith(
      questions: state.questions.where((q) => q.id != questionId).toList(),
    );
  }

  void _replaceQuestion(
    String questionId,
    PersonalQuizQuestionDraft Function(PersonalQuizQuestionDraft) fn,
  ) {
    state = state.copyWith(
      questions: state.questions
          .map((q) => q.id == questionId ? fn(q) : q)
          .toList(),
    );
  }

  void updateQuestionText(String questionId, String text) =>
      _replaceQuestion(questionId, (q) => q.copyWith(text: text));

  void updateQuestionExplanation(String questionId, String explanation) =>
      _replaceQuestion(questionId, (q) => q.copyWith(explanation: explanation));

  void updateQuestionCorrect(String questionId, int index) =>
      _replaceQuestion(questionId, (q) => q.copyWith(correctIndex: index));

  void updateQuestionDirectionOverride(String questionId, String? direction) =>
      _replaceQuestion(
        questionId,
        (q) => direction == null
            ? q.copyWith(clearQuestionDirectionOverride: true)
            : q.copyWith(questionDirectionOverride: direction),
      );

  void updateExplanationDirectionOverride(
          String questionId, String? direction) =>
      _replaceQuestion(
        questionId,
        (q) => direction == null
            ? q.copyWith(clearExplanationDirectionOverride: true)
            : q.copyWith(explanationDirectionOverride: direction),
      );

  void updateQuestionOption(String questionId, int optIdx, String value) {
    _replaceQuestion(questionId, (q) {
      final opts = List<String>.from(q.options);
      if (optIdx < opts.length) opts[optIdx] = value;
      return q.copyWith(options: opts);
    });
  }

  void addQuestionOption(String questionId) {
    _replaceQuestion(
      questionId,
      (q) => q.copyWith(options: [...q.options, '']),
    );
  }

  void removeQuestionOption(String questionId, int optIdx) {
    _replaceQuestion(questionId, (q) {
      if (q.options.length <= 2) return q; // keep at least 2 options
      final opts = List<String>.from(q.options)..removeAt(optIdx);
      var correct = q.correctIndex;
      if (correct >= opts.length) correct = opts.length - 1;
      return q.copyWith(options: opts, correctIndex: correct);
    });
  }

  /// Records a freshly-picked image path, generating an imageId if this
  /// question didn't already have one (kept stable across repeated attaches
  /// so a re-picked image doesn't orphan the previous one's eventual file).
  void setQuestionImage(String questionId, String? path) {
    _replaceQuestion(questionId, (q) {
      if (path == null) return q.copyWith(imagePath: '', imageId: '');
      final imageId = q.imageId.isNotEmpty ? q.imageId : shortId('qimg');
      return q.copyWith(imagePath: path, imageId: imageId);
    });
  }

  /// Appends questions parsed from pasted/uploaded JSON (same format as
  /// Studio's teacher-facing import) to the current draft.
  int addQuestionsFromJson(List<PersonalQuizQuestionDraft> parsed) {
    state = state.copyWith(questions: [...state.questions, ...parsed]);
    return parsed.length;
  }
}

final personalQuizDraftProvider = StateNotifierProvider.autoDispose
    .family<PersonalQuizDraftNotifier, PersonalQuizDraft, String>(
  (ref, draftId) => PersonalQuizDraftNotifier(ref, draftId),
);
