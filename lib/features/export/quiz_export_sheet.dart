import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/quiz.dart';
import '../../core/services/pdf/quiz_pdf_builder.dart';
import '../../core/services/quiz_image_resolver.dart';
import '../../local_server/server_provider.dart';
import '../review/review_deck.dart';
import 'review_deck_export.dart';
import 'single_quiz_anki_export.dart';
import '../../app/theme.dart';

/// Bottom sheet offering export formats for [quiz]. Gated by
/// `quiz.isPersonalQuiz || quiz.exportAllowed` — course quizzes the teacher
/// hasn't opted in show disabled rows with an explanatory subtitle rather
/// than being hidden outright, so students understand why it's unavailable.
Future<void> showQuizExportSheet(
  BuildContext context,
  WidgetRef ref, {
  required Quiz quiz,
  required String lectureId,
}) {
  final canExport = quiz.isPersonalQuiz || quiz.exportAllowed;

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Export Quiz',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (!canExport) ...[
              const SizedBox(height: 6),
              const Text(
                "Your teacher hasn't enabled export for this quiz.",
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
            const SizedBox(height: 8),
            _ExportRow(
              enabled: canExport,
              icon: Icons.style_rounded,
              title: 'Anki deck (.apkg)',
              subtitle: 'Interactive flashcards you can study offline in Anki',
              onTap: () => _exportAnkiAndSave(context, ref,
                  quiz: quiz, lectureId: lectureId),
            ),
            _ExportRow(
              enabled: canExport,
              icon: Icons.description_outlined,
              title: 'PDF — Practice Sheet',
              subtitle: 'Questions and options only, no answers',
              onTap: () => _exportPdfAndShare(context, ref,
                  quiz: quiz,
                  lectureId: lectureId,
                  variant: QuizPdfVariant.unsolved),
            ),
            _ExportRow(
              enabled: canExport,
              icon: Icons.fact_check_outlined,
              title: 'PDF — Answer Key',
              subtitle: 'Correct answers highlighted, with explanations',
              onTap: () => _exportPdfAndShare(context, ref,
                  quiz: quiz,
                  lectureId: lectureId,
                  variant: QuizPdfVariant.solved),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Aggregate variant of [showQuizExportSheet] for a review deck spanning
/// multiple lectures/quizzes (e.g. "export all due questions" from the
/// Review/Starred scope screens). Unlike the single-quiz sheet, this is
/// never fully disabled — any personal-quiz question is always exportable,
/// so there's always something to try; non-exportable course questions are
/// silently dropped from the built file, with the excluded count reported
/// back after the export completes.
Future<void> showReviewExportSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<ReviewQuestion> questions,
  required String deckName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Export Review Deck',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${questions.length} question(s) selected — questions from '
              "quizzes without export enabled won't be included.",
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            _ExportRow(
              enabled: true,
              icon: Icons.style_rounded,
              title: 'Anki deck (.apkg)',
              subtitle: 'Interactive flashcards you can study offline in Anki',
              onTap: () => _exportAggregateAnkiAndSave(context, ref,
                  questions: questions, deckName: deckName),
            ),
            _ExportRow(
              enabled: true,
              icon: Icons.description_outlined,
              title: 'PDF — Practice Sheet',
              subtitle: 'Questions and options only, no answers',
              onTap: () => _exportAggregatePdfAndShare(context, ref,
                  questions: questions,
                  deckName: deckName,
                  variant: QuizPdfVariant.unsolved),
            ),
            _ExportRow(
              enabled: true,
              icon: Icons.fact_check_outlined,
              title: 'PDF — Answer Key',
              subtitle: 'Correct answers highlighted, with explanations',
              onTap: () => _exportAggregatePdfAndShare(context, ref,
                  questions: questions,
                  deckName: deckName,
                  variant: QuizPdfVariant.solved),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ExportRow extends StatelessWidget {
  const _ExportRow({
    required this.enabled,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool enabled;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: Icon(icon, color: enabled ? AppTheme.primary : Colors.white24),
      title: Text(title, style: TextStyle(color: enabled ? Colors.white : Colors.white38)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 12)),
      onTap: enabled
          ? () {
              Navigator.of(context).pop();
              onTap();
            }
          : null,
    );
  }
}

/// Best-effort shelf-server lookup for course-quiz images — only attempted
/// when the quiz actually has images and isn't a personal quiz (which reads
/// its images from plain local files instead). Never blocks the export;
/// on any failure the export simply proceeds text-only.
Future<(int?, String?)> _resolveShelfServer(
  WidgetRef ref, {
  required Quiz quiz,
  required String lectureId,
}) async {
  if (quiz.isPersonalQuiz || !quiz.questions.any((q) => q.hasImage)) {
    return (null, null);
  }
  try {
    final server = await ref
        .read(videoServerProvider(VideoPlaybackArgs(
          lectureId: lectureId,
          videoId: '',
          watermarkEnabled: false,
        )).future)
        .timeout(const Duration(seconds: 8));
    return (server.port, server.sessionToken);
  } catch (_) {
    return (null, null);
  }
}

Future<void> _exportAnkiAndSave(
  BuildContext context,
  WidgetRef ref, {
  required Quiz quiz,
  required String lectureId,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Building Anki deck…')));

  final (shelfPort, shelfToken) =
      await _resolveShelfServer(ref, quiz: quiz, lectureId: lectureId);

  String? resultMessage;
  try {
    final tempDir = await getTemporaryDirectory();
    final file = await exportQuizToAnki(
      quiz,
      lectureId: lectureId,
      outputDir: Directory('${tempDir.path}/anki_exports'),
      shelfPort: shelfPort,
      shelfToken: shelfToken,
    );
    final bytes = await file.readAsBytes();
    final fileName = file.uri.pathSegments.last;

    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Anki Deck',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['apkg'],
      bytes: bytes,
    );

    // On desktop, file_picker's save dialog only returns the chosen path —
    // the caller writes the bytes. On Android/iOS it writes them itself.
    if (savedPath != null &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await File(savedPath).writeAsBytes(bytes);
    }

    resultMessage = savedPath != null ? 'Saved: $savedPath' : 'Export cancelled';
  } on ExportNotAllowedException catch (e) {
    resultMessage = e.toString();
  } catch (e) {
    resultMessage = 'Export failed: $e';
  }

  messenger.showSnackBar(SnackBar(content: Text(resultMessage)));
}

Future<void> _exportPdfAndShare(
  BuildContext context,
  WidgetRef ref, {
  required Quiz quiz,
  required String lectureId,
  required QuizPdfVariant variant,
}) async {
  if (!quiz.isPersonalQuiz && !quiz.exportAllowed) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Export is not allowed for this quiz.')),
    );
    return;
  }

  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Building PDF…')));

  final (shelfPort, shelfToken) =
      await _resolveShelfServer(ref, quiz: quiz, lectureId: lectureId);

  try {
    final images = await QuizImageResolver.resolveQuestionImages(
      quiz,
      lectureId: lectureId,
      shelfPort: shelfPort,
      shelfToken: shelfToken,
    );
    final bytes = await buildQuizPdf(
      quiz,
      variant: variant,
      imagesByQuestionId: images,
    );

    final suffix = variant == QuizPdfVariant.solved ? 'answer_key' : 'practice';
    final safeName = (quiz.title.isEmpty ? 'quiz' : quiz.title)
        .replaceAll(RegExp('[\\\\/:*?"<>|]'), '_')
        .trim();

    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF',
      fileName: '${safeName}_$suffix.pdf',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      bytes: bytes,
    );

    if (savedPath != null &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await File(savedPath).writeAsBytes(bytes);
    }

    messenger.showSnackBar(SnackBar(
        content:
            Text(savedPath != null ? 'Saved: $savedPath' : 'Export cancelled')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
  }
}

/// Shared by both aggregate handlers — resolves a shelf server for
/// [lectureId] the same best-effort way [_resolveShelfServer] does for a
/// single quiz, just wrapped as a [ShelfServerResolver] callback so
/// `review_deck_export.dart` can look one up per-lecture as it iterates a
/// cross-lecture question list.
ShelfServerResolver _makeAggregateShelfResolver(WidgetRef ref) {
  return (lectureId) async {
    try {
      final server = await ref
          .read(videoServerProvider(VideoPlaybackArgs(
            lectureId: lectureId,
            videoId: '',
            watermarkEnabled: false,
          )).future)
          .timeout(const Duration(seconds: 8));
      return (server.port, server.sessionToken);
    } catch (_) {
      return (null, null);
    }
  };
}

String _exclusionSuffix(int excludedCount) => excludedCount > 0
    ? ' ($excludedCount question(s) excluded — export not enabled for that quiz)'
    : '';

Future<void> _exportAggregateAnkiAndSave(
  BuildContext context,
  WidgetRef ref, {
  required List<ReviewQuestion> questions,
  required String deckName,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Building Anki deck…')));

  String? resultMessage;
  try {
    final tempDir = await getTemporaryDirectory();
    final result = await exportReviewQuestionsToAnki(
      questions,
      deckName: deckName,
      outputDir: Directory('${tempDir.path}/anki_exports'),
      resolveShelfServer: _makeAggregateShelfResolver(ref),
    );
    final bytes = await result.data.readAsBytes();
    final fileName = result.data.uri.pathSegments.last;

    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Anki Deck',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['apkg'],
      bytes: bytes,
    );

    if (savedPath != null &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await File(savedPath).writeAsBytes(bytes);
    }

    resultMessage = savedPath != null
        ? 'Saved: $savedPath${_exclusionSuffix(result.excludedCount)}'
        : 'Export cancelled';
  } catch (e) {
    resultMessage = 'Export failed: $e';
  }

  messenger.showSnackBar(SnackBar(content: Text(resultMessage)));
}

Future<void> _exportAggregatePdfAndShare(
  BuildContext context,
  WidgetRef ref, {
  required List<ReviewQuestion> questions,
  required String deckName,
  required QuizPdfVariant variant,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Building PDF…')));

  try {
    final result = await buildReviewDeckPdf(
      questions,
      deckName: deckName,
      variant: variant,
      resolveShelfServer: _makeAggregateShelfResolver(ref),
    );

    final suffix = variant == QuizPdfVariant.solved ? 'answer_key' : 'practice';
    final safeName = (deckName.isEmpty ? 'review_deck' : deckName)
        .replaceAll(RegExp('[\\\\/:*?"<>|]'), '_')
        .trim();

    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF',
      fileName: '${safeName}_$suffix.pdf',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      bytes: result.data,
    );

    if (savedPath != null &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await File(savedPath).writeAsBytes(result.data);
    }

    final suffixMsg = _exclusionSuffix(result.excludedCount);
    messenger.showSnackBar(SnackBar(
        content: Text(savedPath != null
            ? 'Saved: $savedPath$suffixMsg'
            : 'Export cancelled')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
  }
}
