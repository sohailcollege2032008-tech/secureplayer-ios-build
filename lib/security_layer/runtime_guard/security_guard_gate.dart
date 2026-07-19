import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'security_block_screen.dart';
import 'security_guard_state.dart';
import 'security_runtime_guard_service.dart';
import 'security_transient_blackout.dart';

/// Testing-only escape hatch: build with
/// `--dart-define=DEBUG_SHOW_SECURITY_FLAG=true` to render a small,
/// non-obstructive banner over the still-visible content instead of the
/// real opaque blackout on a transient signal. Exists for testing on
/// remote/streamed environments (Appetize.io, LambdaTest, BrowserStack)
/// where the platform's own screen-streaming is itself a form of capture —
/// the real blackout would otherwise cover the session permanently, making
/// the rest of the app impossible to see or test. Never set this in a
/// production build.
const _debugShowSecurityFlagInsteadOfBlackout =
    bool.fromEnvironment('DEBUG_SHOW_SECURITY_FLAG', defaultValue: false);

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
      SecurityGuardTransientHold() => _debugShowSecurityFlagInsteadOfBlackout
          ? _DebugSecurityFlagBanner(child: child)
          : const SecurityTransientBlackout(),
      SecurityGuardViolation(:final reason) =>
        SecurityBlockScreen(reason: reason),
    };
  }
}

class _DebugSecurityFlagBanner extends StatelessWidget {
  const _DebugSecurityFlagBanner({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: 40,
          left: 0,
          right: 0,
          child: Container(
            color: Colors.red,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: const Text(
              'DEBUG: security signal caught (blackout suppressed for testing)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
