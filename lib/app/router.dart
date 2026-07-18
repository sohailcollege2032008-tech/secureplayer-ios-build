import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models/course_metadata.dart';
import '../core/models/quiz.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/courses/course_detail_screen.dart';
import '../features/courses/course_lectures_screen.dart';
import '../features/courses/course_list_screen.dart';
import '../features/quiz/general_quiz_collection_screen.dart';
import '../features/quiz/my_quizzes_screen.dart';
import '../features/quiz/quiz_analytics_screen.dart';
import '../features/quiz/quiz_attempt_result.dart';
import '../features/quiz/quiz_result_screen.dart';
import '../features/quiz/quiz_screen.dart';
import '../features/files/file_viewer_screen.dart';
import '../features/personal_quiz/personal_quiz_editor_screen.dart';
import '../features/personal_quiz/personal_quizzes_screen.dart';
import '../features/review/review_deck.dart';
import '../features/review/review_scope_screen.dart';
import '../features/review/review_session_screen.dart';
import '../features/review/starred_browse_screen.dart';
import '../features/review/starred_scope_screen.dart';
import '../features/video_player/video_player_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refreshListenable = GoRouterRefreshStream(
    FirebaseAuth.instance.authStateChanges(),
  );

  return GoRouter(
    initialLocation: '/courses',
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      final isLoggedIn = FirebaseAuth.instance.currentUser != null;
      final path = state.uri.toString();
      final isPublic =
          path.startsWith('/login') || path.startsWith('/register');

      if (!isLoggedIn && !isPublic) return '/login';
      if (isLoggedIn && isPublic) return '/courses';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (_, __) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/courses',
        builder: (_, __) => const CourseListScreen(),
      ),
      // Course → lecture list (Firestore-fetched, with local import status)
      GoRoute(
        path: '/course/:courseId',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return CourseLecturesScreen(
            courseId: state.pathParameters['courseId']!,
            courseTitle: extra?['title'] as String? ?? '',
          );
        },
      ),
      // Lecture → video list (locally imported lecture)
      GoRoute(
        path: '/lecture/:lectureId',
        builder: (context, state) => CourseDetailScreen(
          courseId: state.pathParameters['lectureId']!,
        ),
      ),
      GoRoute(
        path: '/general-quiz/:collectionId',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return GeneralQuizCollectionScreen(
            collectionId: state.pathParameters['collectionId']!,
            title: extra?['title'] as String? ?? 'Quiz Collection',
          );
        },
      ),
      GoRoute(
        path: '/player/:lectureId/:videoId',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return VideoPlayerScreen(
            lectureId: state.pathParameters['lectureId']!,
            videoId: state.pathParameters['videoId']!,
            title: extra['title'] as String? ?? '',
            watermarkConfig: extra['watermarkConfig'] as WatermarkConfig? ??
                WatermarkConfig.off,
            initialAspectRatio: extra['aspectRatio'] as double?,
          );
        },
      ),
      GoRoute(
        path: '/quiz/:lectureId/:quizId',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return QuizScreen(
            quiz: extra['quiz'] as Quiz,
            lectureId: state.pathParameters['lectureId']!,
            videoId: extra['videoId'] as String?,
            isPopup: extra['isPopup'] as bool? ?? false,
          );
        },
      ),
      GoRoute(
        path: '/quiz-result',
        builder: (context, state) => QuizResultScreen(
          result: state.extra as QuizAttemptResult,
        ),
      ),
      GoRoute(
        path: '/my-quizzes',
        builder: (_, __) => const MyQuizzesScreen(),
      ),
      GoRoute(
        path: '/personal-quizzes',
        builder: (_, __) => const PersonalQuizzesScreen(),
      ),
      GoRoute(
        path: '/personal-quizzes/edit/:draftId',
        builder: (context, state) => PersonalQuizEditorScreen(
          draftId: state.pathParameters['draftId']!,
        ),
      ),
      GoRoute(
        path: '/quiz-analytics/:quizId',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return QuizAnalyticsScreen(
            quizId: state.pathParameters['quizId']!,
            quizTitle: extra?['title'] as String? ?? 'Quiz',
          );
        },
      ),
      GoRoute(
        path: '/review',
        builder: (_, __) => const ReviewScopeScreen(),
      ),
      GoRoute(
        path: '/review/session',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return ReviewSessionScreen(
            lectureIds: List<String>.from(extra['lectureIds'] as List),
            filterMode: ReviewFilterMode.values.firstWhere(
              (m) => m.name == extra['filterMode'] as String?,
              orElse: () => ReviewFilterMode.wholeExam,
            ),
            shuffleAcrossSources: extra['shuffleAcrossSources'] as bool? ?? false,
          );
        },
      ),
      GoRoute(
        path: '/review/starred-scope',
        builder: (_, __) => const StarredScopeScreen(),
      ),
      GoRoute(
        path: '/review/starred',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return StarredBrowseScreen(
            lectureIds: List<String>.from(extra['lectureIds'] as List),
          );
        },
      ),
      GoRoute(
        path: '/file/:lectureId/:fileId',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return FileViewerScreen(
            lectureId: state.pathParameters['lectureId']!,
            fileId: state.pathParameters['fileId']!,
            filename: extra['filename'] as String,
            title: extra['title'] as String? ?? '',
            mimeType: extra['mimeType'] as String? ?? '',
            fileIvMap: Map<String, String>.from(
                extra['fileIvMap'] as Map? ?? const {}),
            watermarkConfig: extra['watermarkConfig'] as WatermarkConfig? ??
                WatermarkConfig.off,
          );
        },
      ),
    ],
    errorBuilder: (_, state) => Scaffold(
      body: Center(
        child: Text(
          'Page not found: ${state.error}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    ),
  );
});

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    notifyListeners();
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
