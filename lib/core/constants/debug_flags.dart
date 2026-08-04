/// Debug affordances that must not exist in a production build.
///
/// Off by default, so a plain `flutter build ipa` is production-clean. Turn
/// on for a diagnostic build:
///
/// ```bash
/// flutter build ipa --dart-define=FAIRPLAY_DEBUG_TOOLS=true
/// ```
///
/// These are gated rather than deleted deliberately. The FairPlay key
/// exchange fails silently — AVPlayer renders nothing and emits no error —
/// so when something does go wrong on a device we cannot attach to, this log
/// is the only evidence that exists. Deleting it means the next incident
/// starts from zero again; gating it means it is one rebuild away.
///
/// What this controls:
///   * the "FairPlay Log" entry in the app drawer
///   * the on-screen `[FP demo]` progress toasts during demo auto-import
///   * whether a playback stall shows the raw native log or a plain message
///
/// It does NOT control writing the log file itself. That stays on always: it
/// is a few lines of text in the app's private container, costs nothing, and
/// means a diagnostic build can read history from before the flag was set.
library debug_flags;

const bool kFairplayDebugTools =
    bool.fromEnvironment('FAIRPLAY_DEBUG_TOOLS', defaultValue: false);
