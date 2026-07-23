import 'package:flutter/material.dart';

import '../review_deck.dart';
import '../../../app/theme.dart';

/// The 4-option ReviewFilterMode picker, shared by the review scope screen
/// (picking what to review right now) and the quiz retake confirmation flow
/// (picking which questions enter/stay in the review pool for that quiz).
class FilterModePicker extends StatelessWidget {
  const FilterModePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ReviewFilterMode value;
  final ValueChanged<ReviewFilterMode> onChanged;

  static const _labels = {
    ReviewFilterMode.wholeExam: 'Whole exam',
    ReviewFilterMode.wrongOnly: 'Wrong only',
    ReviewFilterMode.starredOnly: 'Starred',
    ReviewFilterMode.starredOrWrong: 'Starred + wrong',
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<ReviewFilterMode>(
          segments: [
            for (final mode in ReviewFilterMode.values)
              ButtonSegment(value: mode, label: Text(_labels[mode]!)),
          ],
          selected: {value},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onChanged(selection.first),
          style: SegmentedButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.04),
            foregroundColor: Colors.white54,
            selectedBackgroundColor:
                AppTheme.primary.withValues(alpha: 0.2),
            selectedForegroundColor: AppTheme.secondaryAccent,
            side: const BorderSide(color: Colors.white12),
          ),
        ),
      ),
    );
  }
}
