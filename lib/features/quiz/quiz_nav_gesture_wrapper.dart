import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps quiz question content with touch-swipe, trackpad-drag (Flutter
/// surfaces desktop trackpad swipe through the same drag pointer pipeline —
/// no separate API needed), and arrow-key navigation. All three input modes
/// are gated by [enabled] as one toggle, shared by quiz_screen.dart and
/// quiz_modal.dart so the gesture logic exists in exactly one place.
///
/// Convention (independent of question RTL/LTR content, matching the
/// near-universal mobile-app swipe/arrow convention): swipe left or the
/// right-arrow key means "next"; swipe right or the left-arrow key means
/// "previous".
class QuizNavGestureWrapper extends StatelessWidget {
  const QuizNavGestureWrapper({
    super.key,
    required this.child,
    required this.enabled,
    required this.onNext,
    required this.onPrevious,
  });

  final Widget child;
  final bool enabled;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  static const _swipeVelocityThreshold = 200.0;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          onNext();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          onPrevious();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity.abs() < _swipeVelocityThreshold) return;
          if (velocity < 0) {
            onNext();
          } else {
            onPrevious();
          }
        },
        child: child,
      ),
    );
  }
}
