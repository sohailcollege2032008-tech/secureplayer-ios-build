import 'package:flutter/material.dart';

import '../../../core/models/review_settings.dart';
import '../../../core/services/srs_scheduler.dart';

/// The four SRS rating buttons shown after answering a review question.
/// Always displays all four regardless of answer correctness (user decision).
/// Each button previews the interval that rating would schedule.
class RatingBar extends StatelessWidget {
  const RatingBar({
    super.key,
    required this.reps,
    required this.intervalMin,
    required this.settings,
    required this.onRate,
  });

  /// Previous SRS state of the current question (0/0 when never reviewed) —
  /// used only to compute the predicted-interval subtitles.
  final int reps;
  final double intervalMin;
  final ReviewSettings settings;
  final ValueChanged<ReviewRating> onRate;

  String _predict(ReviewRating rating) {
    final next = SrsScheduler.next(
      reps: reps,
      intervalMin: intervalMin,
      rating: rating,
      now: DateTime.now(),
      settings: settings,
    );
    return SrsScheduler.formatInterval(next.intervalMin);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _RatingButton(
          label: 'غلط',
          subtitle: _predict(ReviewRating.again),
          color: Colors.redAccent,
          onTap: () => onRate(ReviewRating.again),
        ),
        const SizedBox(width: 8),
        _RatingButton(
          label: 'صعب',
          subtitle: _predict(ReviewRating.hard),
          color: Colors.orangeAccent,
          onTap: () => onRate(ReviewRating.hard),
        ),
        const SizedBox(width: 8),
        _RatingButton(
          label: 'متوسط',
          subtitle: _predict(ReviewRating.medium),
          color: const Color(0xFF6C63FF),
          onTap: () => onRate(ReviewRating.medium),
        ),
        const SizedBox(width: 8),
        _RatingButton(
          label: 'سهل',
          subtitle: _predict(ReviewRating.easy),
          color: Colors.greenAccent,
          onTap: () => onRate(ReviewRating.easy),
        ),
      ],
    );
  }
}

class _RatingButton extends StatelessWidget {
  const _RatingButton({
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: color.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
