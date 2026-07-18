/// Every distinct cause the runtime security guard can report. Kept this
/// granular (rather than a single bool) because the block screen shown for
/// [SecurityGuardViolation] must tell the student exactly what's wrong and
/// exactly how to fix it — there is deliberately no "exit" button, so the
/// message has to be actionable on its own.
enum SecurityGuardReason {
  adbEnabled,
  developerOptionsEnabled,
  fridaDetected,
  rooted,
  xposed,
  magiskHidden,
  flagSecureMissing,
  signatureInvalid,
  emulatorDetected,
  debuggableBuild,
  virtualMachineDetected,
  debuggerAttached,
}

sealed class SecurityGuardState {
  const SecurityGuardState();
}

/// Nothing suspicious — content renders normally.
class SecurityGuardClear extends SecurityGuardState {
  const SecurityGuardClear();
}

/// A benign-until-proven-otherwise signal fired (window lost focus, HDMI
/// connected, screen recording started). Content is briefly blacked out
/// while the guard re-verifies; self-clears the instant the recheck comes
/// back clean, typically well under a second.
class SecurityGuardTransientHold extends SecurityGuardState {
  const SecurityGuardTransientHold();
}

/// A real violation was confirmed. The block screen for [reason] is shown
/// with no escape hatch — it only clears when [reason] itself goes away,
/// verified by the same ongoing recheck.
class SecurityGuardViolation extends SecurityGuardState {
  const SecurityGuardViolation(this.reason);
  final SecurityGuardReason reason;
}
