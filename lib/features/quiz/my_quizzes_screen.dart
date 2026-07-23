import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'quiz_history_service.dart';
import '../../app/theme.dart';

class MyQuizzesScreen extends ConsumerWidget {
  const MyQuizzesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(groupedQuizAttemptsProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        foregroundColor: Colors.white,
        title: const Text(
          'My Quizzes',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: groupsAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(
          child: Text(e.toString(),
              style: const TextStyle(color: Colors.white54)),
        ),
        data: (groups) {
          if (groups.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.quiz_outlined,
                        size: 72,
                        color: Colors.white.withValues(alpha: 0.15)),
                    const SizedBox(height: 20),
                    const Text(
                      'No quizzes taken yet',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Complete a quiz from a lecture\nto see your history here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 14,
                          height: 1.5),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: groups.length,
            itemBuilder: (_, i) => _AttemptGroupCard(group: groups[i]),
          );
        },
      ),
    );
  }
}

Color _scoreColor(double pct) => pct >= 0.7
    ? Colors.greenAccent
    : pct >= 0.5
        ? Colors.orangeAccent
        : Colors.redAccent;

String _dateLabel(DateTime d) => '${d.day}/${d.month}/${d.year}';

class _AttemptGroupCard extends StatefulWidget {
  const _AttemptGroupCard({required this.group});
  final GroupedQuizAttempts group;

  @override
  State<_AttemptGroupCard> createState() => _AttemptGroupCardState();
}

class _AttemptGroupCardState extends State<_AttemptGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final attempt = group.mostRecent;
    final pct = attempt.totalQuestions == 0
        ? 0.0
        : attempt.correctCount / attempt.totalQuestions;
    final color = _scoreColor(pct);
    final hasMultiple = group.attemptCount > 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: hasMultiple ? () => setState(() => _expanded = !_expanded) : null,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: color, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        '${(pct * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          attempt.quizTitle.isNotEmpty
                              ? attempt.quizTitle
                              : 'Quiz',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              attempt.scoreLabel,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            const Text('·',
                                style: TextStyle(color: Colors.white38)),
                            const SizedBox(width: 8),
                            Text(
                              attempt.formattedTime,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            const Text('·',
                                style: TextStyle(color: Colors.white38)),
                            const SizedBox(width: 8),
                            Text(
                              _dateLabel(attempt.attemptedAt),
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 12),
                            ),
                          ],
                        ),
                        if (hasMultiple) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Attempted ${group.attemptCount} times',
                            style: const TextStyle(
                              color: AppTheme.secondaryAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (hasMultiple)
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: Colors.white38,
                    ),
                ],
              ),
            ),
          ),
          if (_expanded && hasMultiple)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1, color: Color(0x14FFFFFF)),
                  const SizedBox(height: 8),
                  ...group.attempts.map(_buildAttemptChip),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAttemptChip(LocalQuizAttempt a) {
    final pct = a.totalQuestions == 0 ? 0.0 : a.correctCount / a.totalQuestions;
    final color = _scoreColor(pct);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 10),
          Text(
            a.scoreLabel,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w600, fontSize: 12),
          ),
          const SizedBox(width: 10),
          Text(
            a.formattedTime,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(width: 10),
          Text(
            _dateLabel(a.attemptedAt),
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
