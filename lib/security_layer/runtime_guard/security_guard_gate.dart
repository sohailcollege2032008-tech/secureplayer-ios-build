import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'security_block_screen.dart';
import 'security_guard_state.dart';
import 'security_runtime_guard_service.dart';
import 'security_transient_blackout.dart';

/// Wraps a protected screen's content. Renders [child] when clear, a brief
/// blackout on a transient signal, and the no-escape-hatch block screen on a
/// confirmed violation. Every screen that renders decrypted content (video,
/// file, quiz, review) wraps its body in exactly one of these — the guard
/// itself is shared (see [securityRuntimeGuardProvider]), only this gate
/// widget is per-screen.
class SecurityGuardGate extends ConsumerWidget {
  const SecurityGuardGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(securityRuntimeGuardProvider);
    return switch (state) {
      SecurityGuardClear() => child,
      SecurityGuardTransientHold() => const SecurityTransientBlackout(),
      SecurityGuardViolation(:final reason) =>
        SecurityBlockScreen(reason: reason),
    };
  }
}
