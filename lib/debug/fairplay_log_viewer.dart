import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../security_layer/fairplay/fairplay_service.dart';

/// ── DEBUG-ONLY (branch `debug-fairplay-logviewer`) ─────────────────────────
///
/// In-app viewer for the native FairPlay diagnostics log
/// (`Documents/fairplay_diagnostics.log`, written by Swift on its own queue,
/// independent of the Dart UI). Purpose: let Osama grab the full key-exchange
/// transcript at ANY moment — before playing, after a freeze, after force-quit
/// — without relying on the 20s stall watchdog rendering (which cannot run if
/// the main thread itself is frozen).
///
/// Remove ALL of this together with the native `uploadStallLog` code and the
/// `reportFairplayStallLog` Cloud Function once the stall is fixed. The single
/// flag below gates every insertion point.
const bool kFairplayDebugLogViewerEnabled = true;

/// The one button used everywhere (course list app bar, video player overlay).
/// Tapping it shows the log in a modal bottom sheet with copy support.
class FairplayDebugLogButton extends StatelessWidget {
  const FairplayDebugLogButton({super.key, this.color = Colors.white70});

  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!kFairplayDebugLogViewerEnabled) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'FairPlay debug log',
      icon: Icon(Icons.bug_report_rounded, color: color, size: 20),
      onPressed: () => showFairplayLogSheet(context),
    );
  }
}

/// Reads the log and shows it. Callable from anywhere; the log file persists
/// across app restarts (only truncated when a NEW playback attempt begins —
/// FairplayDiagnostics.reset() in BetterPlayer.swift), so after force-quitting
/// a frozen app, relaunching and opening this sheet still shows the crashed
/// attempt's log.
Future<void> showFairplayLogSheet(BuildContext context) async {
  if (!kFairplayDebugLogViewerEnabled) return;

  final diagnostics = await FairplayService.readDiagnostics();
  if (!context.mounted) return;

  final body = diagnostics.isEmpty
      ? '(log empty — the native key delegate was never called)'
      : diagnostics;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF171717),
    isScrollControlled: true,
    builder: (sheetCtx) {
      final text = body;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'FairPlay diagnostics',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (sheetCtx.mounted) {
                          ScaffoldMessenger.of(sheetCtx).showSnackBar(
                            const SnackBar(
                              content: Text('Log copied to clipboard'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy all'),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70),
                      onPressed: () => Navigator.of(sheetCtx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    text,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
