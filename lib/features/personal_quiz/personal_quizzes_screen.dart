import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/quiz.dart';
import '../export/quiz_export_sheet.dart';
import 'personal_quiz_draft_state.dart';
import 'personal_quiz_generator.dart';
import 'personal_quiz_provider.dart';

const _kBg = Color(0xFF0D0D0D);
const _kCard = Color(0xFF1A1A2E);
const _kAccent = Color(0xFF6C63FF);

/// Lists every quiz the student has authored themselves — separate from
/// `/my-quizzes` (that screen is attempt *history*, see quiz_history_service
/// .dart; this one is quiz *authorship*). Reachable from the app drawer.
class PersonalQuizzesScreen extends ConsumerWidget {
  const PersonalQuizzesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quizzesAsync = ref.watch(personalQuizzesProvider);

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        foregroundColor: Colors.white,
        title: const Text('Personal Quizzes',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Create new quiz',
            onPressed: () => _createNew(context, ref),
          ),
        ],
      ),
      body: quizzesAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: _kAccent)),
        error: (e, _) => Center(
          child: Text('Could not load quizzes: $e',
              style: const TextStyle(color: Colors.white70)),
        ),
        data: (quizzes) {
          if (quizzes.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.edit_note_rounded,
                        color: Colors.white24, size: 64),
                    const SizedBox(height: 16),
                    const Text(
                      "You haven't created any quizzes yet.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => _createNew(context, ref),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: _kAccent, foregroundColor: Colors.white),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Create your first quiz'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: quizzes.length,
            itemBuilder: (_, i) => _PersonalQuizCard(quiz: quizzes[i]),
          );
        },
      ),
    );
  }

  Future<void> _createNew(BuildContext context, WidgetRef ref) async {
    final draftId = shortId('personal_quiz');
    final changed = await context.push<bool>(
      '/personal-quizzes/edit/$draftId',
    );
    if (changed == true) ref.invalidate(personalQuizzesProvider);
  }
}

class _PersonalQuizCard extends ConsumerWidget {
  const _PersonalQuizCard({required this.quiz});

  final Quiz quiz;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  quiz.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _kAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('${quiz.questions.length} questions',
                    style: const TextStyle(color: _kAccent, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _ActionButton(
                icon: Icons.play_arrow_rounded,
                label: 'Take',
                onTap: () => _take(context),
              ),
              _ActionButton(
                icon: Icons.edit_outlined,
                label: 'Edit',
                onTap: () => _edit(context, ref),
              ),
              _ActionButton(
                icon: Icons.ios_share_rounded,
                label: 'Export',
                onTap: () => showQuizExportSheet(
                  context,
                  ref,
                  quiz: quiz,
                  lectureId: 'personal:${quiz.id}',
                ),
              ),
              _ActionButton(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                color: Colors.redAccent,
                onTap: () => _delete(context, ref),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _take(BuildContext context) {
    context.push('/quiz/personal:${quiz.id}/${quiz.id}', extra: {
      'quiz': quiz,
      'isPopup': false,
    });
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final draft = draftFromPersonalQuiz(quiz);
    final notifier = ref.read(personalQuizDraftProvider(draft.id).notifier);
    // Seed the draft provider with the reverse-mapped quiz before opening the
    // editor, so it doesn't try to load a (nonexistent) draft file first.
    notifier.state = draft;

    if (!context.mounted) return;
    final changed =
        await context.push<bool>('/personal-quizzes/edit/${draft.id}');
    if (changed == true) ref.invalidate(personalQuizzesProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        title: const Text('Delete quiz?', style: TextStyle(color: Colors.white)),
        content: Text('This permanently deletes "${quiz.title}".',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await deletePersonalQuiz(quiz.id);
    ref.invalidate(personalQuizzesProvider);
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = _kAccent,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(color: color, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}
