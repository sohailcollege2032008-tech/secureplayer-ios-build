import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/quiz_settings.dart';
import 'quiz_settings_provider.dart';

const _kPrimary = Color(0xFF6C63FF);
const _kSurface = Color(0xFF1A1A2E);

/// Opens the quiz settings bottom sheet. Call from the settings icon in the
/// quiz UI's top corner (quiz_screen.dart / quiz_modal.dart).
Future<void> showQuizSettingsSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: _kSurface,
    // Without this, showModalBottomSheet caps the sheet's height at 9/16 of
    // the available space — fine in a maximized window, but a smaller
    // windowed size shrinks that cap below what the fixed-height content
    // (title + 3 switches + layout selector + font slider) needs, causing a
    // RenderFlex overflow. isScrollControlled lets the sheet size to content
    // (or scroll, via the SingleChildScrollView below) instead.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const QuizSettingsSheet(),
  );
}

class QuizSettingsSheet extends ConsumerWidget {
  const QuizSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(quizSettingsProvider);
    final notifier = ref.read(quizSettingsProvider.notifier);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Row(
              children: [
                Icon(Icons.tune_rounded, color: _kPrimary, size: 20),
                SizedBox(width: 8),
                Text(
                  'Quiz Settings',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _SwitchRow(
              label: 'Shuffle questions',
              value: settings.shuffleQuestions,
              onChanged: notifier.setShuffleQuestions,
            ),
            _SwitchRow(
              label: 'Shuffle answer options',
              value: settings.shuffleOptions,
              onChanged: notifier.setShuffleOptions,
            ),
            _SwitchRow(
              label: 'Swipe / arrow-key navigation',
              value: settings.swipeNavigationEnabled,
              onChanged: notifier.setSwipeNavigationEnabled,
            ),
            const SizedBox(height: 12),
            const Text(
              'Layout',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 8),
            _LayoutModeSelector(
              value: settings.layoutMode,
              onChanged: notifier.setLayoutMode,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text(
                  'Font size',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const Spacer(),
                Text(
                  settings.fontSize.toStringAsFixed(0),
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: _kPrimary,
                thumbColor: _kPrimary,
                inactiveTrackColor: Colors.white12,
              ),
              child: Slider(
                value: settings.fontSize,
                min: QuizSettings.minFontSize,
                max: QuizSettings.maxFontSize,
                divisions:
                    (QuizSettings.maxFontSize - QuizSettings.minFontSize)
                        .toInt(),
                onChanged: notifier.setFontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      activeColor: _kPrimary,
      title: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
    );
  }
}

class _LayoutModeSelector extends StatelessWidget {
  const _LayoutModeSelector({required this.value, required this.onChanged});

  final QuizLayoutMode value;
  final ValueChanged<QuizLayoutMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ModeChip(
            label: 'One per page',
            selected: value == QuizLayoutMode.perPage,
            onTap: () => onChanged(QuizLayoutMode.perPage),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ModeChip(
            label: 'Scrollable',
            selected: value == QuizLayoutMode.scrollAll,
            onTap: () => onChanged(QuizLayoutMode.scrollAll),
          ),
        ),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _kPrimary.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _kPrimary : Colors.white12),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? _kPrimary : Colors.white70,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
