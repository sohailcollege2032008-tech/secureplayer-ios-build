import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'security_runtime_guard_service.dart';

/// Wires a [ConsumerState] into the shared [securityRuntimeGuardProvider]
/// without auto-overriding [didChangeAppLifecycleState] — hosts that already
/// implement that method themselves (for playback pause/resume) call
/// [notifyAppResumedForSecurity] from their own override instead, so this
/// mixin can't silently collide with it.
mixin SecurityRuntimeGuardMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  // Cached in startSecurityGuard() — stopSecurityGuard() cannot do its own
  // ref.read() lookup. Flutter's StatefulElement.unmount() calls
  // super.unmount() (which marks the element defunct, so context.mounted
  // becomes false) BEFORE calling State.dispose() — meaning `ref` is
  // already unusable for the entire duration of dispose(), for every
  // ConsumerStatefulWidget, not just this one. A fresh ref.read() here threw
  // 'Bad state: Cannot use "ref" after the widget was disposed.' on every
  // single exit, which aborted the rest of the host's dispose() body (e.g.
  // VideoPlayerScreen's player teardown never ran) since nothing caught it.
  SecurityRuntimeGuardController? _cachedGuardController;

  /// Call from [initState], after `super.initState()`.
  void startSecurityGuard() {
    final controller = ref.read(securityRuntimeGuardProvider.notifier);
    _cachedGuardController = controller;
    controller.activate();
  }

  /// Call from [dispose], before `super.dispose()`.
  void stopSecurityGuard() {
    _cachedGuardController?.deactivate();
  }

  /// Call from the host's own `didChangeAppLifecycleState` when
  /// `state == AppLifecycleState.resumed`.
  void notifyAppResumedForSecurity() {
    _cachedGuardController?.recheckNow();
  }
}
