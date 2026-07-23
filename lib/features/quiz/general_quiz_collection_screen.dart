import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/loading_indicator.dart';
import 'quiz_provider.dart';
import '../../app/theme.dart';

/// Lists the quizzes inside one standalone General Quiz collection (imported
/// from a `.secquiz` file). Tapping a quiz reuses the existing
/// `/quiz/:lectureId/:quizId` route unchanged — collectionId is passed in
/// place of lectureId, since QuizScreen/videoServerProvider/secure storage
/// all treat that id as an opaque storage key, not literally a lecture.
class GeneralQuizCollectionScreen extends ConsumerWidget {
  const GeneralQuizCollectionScreen({
    super.key,
    required this.collectionId,
    required this.title,
  });

  final String collectionId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quizzesAsync = ref.watch(generalQuizzesProvider(collectionId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: quizzesAsync.when(
        loading: () => const Center(child: LoadingIndicator()),
        error: (e, _) => Center(
          child: Text('$e', style: const TextStyle(color: Colors.white54)),
        ),
        data: (quizzes) {
          if (quizzes.isEmpty) {
            return const Center(
              child: Text(
                'No quizzes in this collection.',
                style: TextStyle(color: Colors.white54),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: quizzes.length,
            itemBuilder: (_, i) {
              final quiz = quizzes[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.quiz_rounded,
                        color: AppTheme.primary, size: 22),
                  ),
                  title: Text(
                    quiz.title.isNotEmpty ? quiz.title : 'Quiz',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Text(
                    '${quiz.questions.length} question${quiz.questions.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: Colors.white38, size: 22),
                  onTap: () => context.push(
                    '/quiz/$collectionId/${quiz.id}',
                    extra: {'quiz': quiz},
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
