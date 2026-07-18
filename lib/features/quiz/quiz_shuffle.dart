import 'dart:math';

import '../../core/models/quiz.dart';

/// Presentation-order layer over an immutable [Quiz] — never mutates the
/// original questions/options loaded from quizzes.json. Turning shuffling
/// off just means the original, untouched order is used again, so "reversible
/// to original order" needs no special handling.
class ShuffledQuiz {
  ShuffledQuiz(
    this.original, {
    required bool shuffleQuestions,
    required bool shuffleOptions,
    int? seed,
  }) {
    final rng = Random(seed);
    final qCount = original.questions.length;

    questionOrder = shuffleQuestions
        ? (List<int>.generate(qCount, (i) => i)..shuffle(rng))
        : List<int>.generate(qCount, (i) => i);

    _optionOrders = List.generate(qCount, (displayIdx) {
      final origQuestion = original.questions[questionOrder[displayIdx]];
      final optCount = origQuestion.options.length;
      if (!shuffleOptions) return List<int>.generate(optCount, (i) => i);
      return List<int>.generate(optCount, (i) => i)..shuffle(rng);
    });
  }

  /// Reconstructs a previously-shuffled order exactly (for resuming an
  /// in-progress attempt) — bypasses the Random-based shuffle entirely so a
  /// resumed quiz's questions/options land in precisely the same display
  /// positions the student already answered against.
  ShuffledQuiz.fromSavedOrder(
    this.original, {
    required List<int> questionOrder,
    required List<List<int>> optionOrders,
  }) {
    this.questionOrder = questionOrder;
    _optionOrders = optionOrders;
  }

  final Quiz original;

  /// display index -> original question index.
  late final List<int> questionOrder;

  /// display index -> (display option index -> original option index).
  late final List<List<int>> _optionOrders;

  /// Read-only view of the option orders, for persisting resume state
  /// (quiz_screen.dart can't reach the private field directly).
  List<List<int>> get optionOrdersForPersistence =>
      List.unmodifiable(_optionOrders.map(List<int>.unmodifiable));

  int get length => original.questions.length;

  int originalQuestionIndex(int displayIndex) => questionOrder[displayIndex];

  /// Reshuffles live, in response to a settings change while a quiz is
  /// already open. [frozenDisplayIndices] are left exactly as they are
  /// (their original question AND option order) — used for anything already
  /// answered or currently on screen, so a live toggle can never silently
  /// change a question out from under an answer the student already gave.
  /// Everything else is freshly reshuffled from the pool of original
  /// questions not already used by the frozen set.
  ShuffledQuiz reshuffleFrom({
    required Set<int> frozenDisplayIndices,
    required bool shuffleQuestions,
    required bool shuffleOptions,
  }) {
    final total = length;
    final rng = Random();
    final newQuestionOrder = List<int>.filled(total, -1);
    final usedOriginal = <int>{};
    for (final i in frozenDisplayIndices) {
      newQuestionOrder[i] = questionOrder[i];
      usedOriginal.add(questionOrder[i]);
    }
    final remainingOriginal = List<int>.generate(total, (i) => i)
        .where((i) => !usedOriginal.contains(i))
        .toList();
    if (shuffleQuestions) remainingOriginal.shuffle(rng);
    var ptr = 0;
    for (var i = 0; i < total; i++) {
      if (newQuestionOrder[i] == -1) {
        newQuestionOrder[i] = remainingOriginal[ptr++];
      }
    }

    final newOptionOrders = List<List<int>>.generate(total, (displayIdx) {
      if (frozenDisplayIndices.contains(displayIdx)) {
        return _optionOrders[displayIdx];
      }
      final origQuestion = original.questions[newQuestionOrder[displayIdx]];
      final optCount = origQuestion.options.length;
      if (!shuffleOptions) return List<int>.generate(optCount, (i) => i);
      return List<int>.generate(optCount, (i) => i)..shuffle(rng);
    });

    return ShuffledQuiz.fromSavedOrder(
      original,
      questionOrder: newQuestionOrder,
      optionOrders: newOptionOrders,
    );
  }

  /// The question for [displayIndex], with options reordered per the shuffle
  /// and correctIndex remapped so it points into the *shuffled* options list.
  /// Callers (quiz_screen.dart, quiz_modal.dart) can treat the result exactly
  /// like a normal QuizQuestion — no shuffle-awareness needed downstream.
  QuizQuestion questionAt(int displayIndex) {
    final origQuestion = original.questions[questionOrder[displayIndex]];
    final order = _optionOrders[displayIndex];
    final shuffledOptions = order.map((i) => origQuestion.options[i]).toList();
    final remappedCorrectIndex = order.indexOf(origQuestion.correctIndex);
    return QuizQuestion(
      id: origQuestion.id,
      text: origQuestion.text,
      options: shuffledOptions,
      correctIndex: remappedCorrectIndex,
      explanation: origQuestion.explanation,
      imageId: origQuestion.imageId,
      questionDirectionOverride: origQuestion.questionDirectionOverride,
      explanationDirectionOverride: origQuestion.explanationDirectionOverride,
    );
  }
}
