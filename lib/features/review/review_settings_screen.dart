import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/review_settings.dart';
import 'review_settings_provider.dart';
import '../../app/theme.dart';

const _kPrimary = AppTheme.primary;
const _kSurface = AppTheme.surface;

/// Opens the review settings bottom sheet. Call from the settings icon in
/// review_session_screen.dart's AppBar.
Future<void> showReviewSettingsSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: _kSurface,
    // Same fix as showQuizSettingsSheet — without this the sheet is capped
    // at 9/16 of the available height, which overflows in a windowed (not
    // maximized) desktop window given how much content is here.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const ReviewSettingsSheet(),
  );
}

class ReviewSettingsSheet extends ConsumerWidget {
  const ReviewSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(reviewSettingsProvider);
    final notifier = ref.read(reviewSettingsProvider.notifier);

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
                  'Review Settings',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _SectionLabel('Desired retention'),
            const SizedBox(height: 4),
            const Text(
              'Higher = shorter intervals, reviewed more often. Lower = '
              'longer intervals, more forgetting risk allowed.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            _SettingSlider(
              label: 'Retention',
              value: settings.retentionPercent,
              unit: '%',
              min: ReviewSettings.minRetentionPercent,
              max: ReviewSettings.maxRetentionPercent,
              divisions: 50,
              onChanged: notifier.setRetentionPercent,
            ),
            const SizedBox(height: 16),
            const _SectionLabel('First shown again after'),
            _SettingSlider(
              label: 'Wrong',
              value: settings.wrongIntervalMin,
              unit: 'm',
              min: 1,
              max: 60,
              divisions: 59,
              onChanged: notifier.setWrongIntervalMin,
            ),
            _SettingSlider(
              label: 'Hard',
              value: settings.hardFloorMin,
              unit: 'm',
              min: 60,
              max: 2880,
              divisions: 47,
              onChanged: notifier.setHardFloorMin,
            ),
            _SettingSlider(
              label: 'Medium',
              value: settings.mediumFirstMin,
              unit: 'm',
              min: 60,
              max: 2880,
              divisions: 47,
              onChanged: notifier.setMediumFirstMin,
            ),
            _SettingSlider(
              label: 'Easy',
              value: settings.easyFirstMin,
              unit: 'm',
              min: 60,
              max: 4320,
              divisions: 71,
              onChanged: notifier.setEasyFirstMin,
            ),
            const SizedBox(height: 16),
            const _SectionLabel('Growth on repeat success'),
            _SettingSlider(
              label: 'Hard ×',
              value: settings.hardMultiplier,
              unit: 'x',
              min: 1.0,
              max: 3.0,
              divisions: 20,
              fractionDigits: 1,
              onChanged: notifier.setHardMultiplier,
            ),
            _SettingSlider(
              label: 'Medium ×',
              value: settings.mediumMultiplier,
              unit: 'x',
              min: 1.0,
              max: 5.0,
              divisions: 40,
              fractionDigits: 1,
              onChanged: notifier.setMediumMultiplier,
            ),
            _SettingSlider(
              label: 'Easy ×',
              value: settings.easyMultiplier,
              unit: 'x',
              min: 1.0,
              max: 8.0,
              divisions: 70,
              fractionDigits: 1,
              onChanged: notifier.setEasyMultiplier,
            ),
            const SizedBox(height: 16),
            const _SectionLabel('Same-session cooldown'),
            const SizedBox(height: 4),
            const Text(
              'Minimum time before a question you just rated can be shown '
              'again in this same review session.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            _SettingSlider(
              label: 'Cooldown',
              value: settings.cooldownSeconds.toDouble(),
              unit: 's',
              min: 10,
              max: 600,
              divisions: 59,
              onChanged: (v) => notifier.setCooldownSeconds(v.round()),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.fractionDigits = 0,
  });

  final String label;
  final double value;
  final String unit;
  final double min;
  final double max;
  final int divisions;
  final int fractionDigits;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const Spacer(),
            Text(
              '${value.toStringAsFixed(fractionDigits)}$unit',
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
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
