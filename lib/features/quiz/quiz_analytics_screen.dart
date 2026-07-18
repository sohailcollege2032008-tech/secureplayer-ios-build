import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'quiz_history_service.dart';

/// The student's own attempt history for one quiz — replaces the leaderboard
/// button's old spot on quiz_result_screen.dart. Reuses groupedQuizAttemptsProvider
/// (already fetched for My Quizzes) rather than a new query.
class QuizAnalyticsScreen extends ConsumerWidget {
  const QuizAnalyticsScreen({
    super.key,
    required this.quizId,
    required this.quizTitle,
  });

  final String quizId;
  final String quizTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(groupedQuizAttemptsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        foregroundColor: Colors.white,
        title: Text(
          quizTitle,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
      body: groupsAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFF6C63FF))),
        error: (e, _) => Center(
            child:
                Text(e.toString(), style: const TextStyle(color: Colors.white54))),
        data: (groups) {
          GroupedQuizAttempts? group;
          for (final g in groups) {
            if (g.quizId == quizId) {
              group = g;
              break;
            }
          }
          if (group == null || group.attempts.isEmpty) {
            return const Center(
              child: Text(
                'No attempts recorded yet.',
                style: TextStyle(color: Colors.white54),
              ),
            );
          }
          return _buildContent(group);
        },
      ),
    );
  }

  double _pct(LocalQuizAttempt a) =>
      a.totalQuestions == 0 ? 0.0 : a.correctCount / a.totalQuestions;

  Widget _buildContent(GroupedQuizAttempts group) {
    var best = group.attempts.first;
    for (final a in group.attempts) {
      if (_pct(a) > _pct(best)) best = a;
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
                child: _StatCard(
                    label: 'Attempts', value: '${group.attemptCount}')),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(label: 'Best score', value: best.scoreLabel)),
            const SizedBox(width: 12),
            Expanded(
                child: _StatCard(
                    label: 'Latest', value: group.mostRecent.scoreLabel)),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          'All attempts',
          style: TextStyle(
              color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ...group.attempts.map((a) => _AttemptRow(attempt: a, isBest: a == best)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
                color: Color(0xFF9C95FF),
                fontSize: 18,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _AttemptRow extends StatelessWidget {
  const _AttemptRow({required this.attempt, required this.isBest});
  final LocalQuizAttempt attempt;
  final bool isBest;

  @override
  Widget build(BuildContext context) {
    final d = attempt.attemptedAt;
    final dateStr = '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isBest
              ? const Color(0xFF6C63FF).withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          if (isBest) ...[
            const Icon(Icons.emoji_events_rounded, color: Colors.amber, size: 16),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              dateStr,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Text(
            attempt.formattedTime,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(width: 14),
          Text(
            attempt.scoreLabel,
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
