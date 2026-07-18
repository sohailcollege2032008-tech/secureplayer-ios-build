import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show TextDirection;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/services/anki/anki_package_builder.dart';
import '../../core/services/pdf/quiz_pdf_builder.dart';
import '../../core/services/quiz_image_resolver.dart';
import '../review/review_deck.dart';

/// Resolves an active shelf server's (port, token) for [lectureId], or
/// (null, null) if none is running — used for best-effort course-quiz image
/// fetching across an aggregate export that may span several lectures.
typedef ShelfServerResolver = Future<(int?, String?)> Function(
    String lectureId);

/// Result of an aggregate export — callers use [excludedCount] to tell the
/// student some questions were left out rather than silently shipping a
/// shorter-than-expected deck.
class AggregateExportResult<T> {
  const AggregateExportResult({
    required this.data,
    required this.includedCount,
    required this.excludedCount,
  });

  final T data;
  final int includedCount;
  final int excludedCount;
}

/// Questions whose parent quiz hasn't enabled export are dropped from the
/// aggregate — personal-quiz questions are always included (the student
/// owns that content).
List<ReviewQuestion> _filterExportable(List<ReviewQuestion> questions) =>
    questions.where((q) => q.isPersonalQuiz || q.exportAllowed).toList();

/// Best-effort image resolution for one [ReviewQuestion], caching the
/// shelf-server lookup per lecture since several questions in the same
/// aggregate export commonly share a lecture.
Future<Uint8List?> _resolveImage(
  ReviewQuestion rq,
  Map<String, (int?, String?)> shelfCache,
  ShelfServerResolver? resolveShelfServer,
) async {
  if (!rq.question.hasImage) return null;
  int? port;
  String? token;
  if (!rq.isPersonalQuiz && resolveShelfServer != null) {
    final cached =
        shelfCache[rq.lectureId] ??= await resolveShelfServer(rq.lectureId);
    port = cached.$1;
    token = cached.$2;
  }
  return QuizImageResolver.resolveOneImage(
    isPersonalQuiz: rq.isPersonalQuiz,
    quizId: rq.quizId,
    lectureId: rq.lectureId,
    imageId: rq.question.imageId,
    shelfPort: port,
    shelfToken: token,
  );
}

/// Builds one Anki deck from [questions], which may span multiple
/// lectures/quizzes (e.g. "export all due questions" from the Review scope
/// screen). Non-exportable questions are silently excluded from the deck
/// contents — report [AggregateExportResult.excludedCount] to the student
/// rather than blocking the whole export over mixed permissions.
Future<AggregateExportResult<File>> exportReviewQuestionsToAnki(
  List<ReviewQuestion> questions, {
  required String deckName,
  required Directory outputDir,
  ShelfServerResolver? resolveShelfServer,
  String? ankiBuildTempDirPath,
}) async {
  final exportable = _filterExportable(questions);
  final builder = AnkiPackageBuilder(deckName: deckName);
  final shelfCache = <String, (int?, String?)>{};

  for (final rq in exportable) {
    final imageBytes = await _resolveImage(rq, shelfCache, resolveShelfServer);
    builder.addQuestion(
      questionId: rq.question.id,
      quizId: rq.quizId,
      questionText: rq.question.text,
      options: rq.question.options,
      correctIndex: rq.question.correctIndex,
      explanation: rq.question.explanation,
      questionDirection:
          rq.question.questionDirectionOverride ?? rq.quizQuestionDirection,
      explanationDirection: rq.question.explanationDirectionOverride ??
          rq.quizExplanationDirection,
      imageBytes: imageBytes,
      source: deckName,
    );
  }

  final bytes = await builder.build(tempDirPath: ankiBuildTempDirPath);
  if (!await outputDir.exists()) {
    await outputDir.create(recursive: true);
  }
  final safeName = deckName.replaceAll(RegExp('[\\\\/:*?"<>|]'), '_').trim();
  final file = File('${outputDir.path}/$safeName.apkg');
  await file.writeAsBytes(bytes);

  return AggregateExportResult(
    data: file,
    includedCount: exportable.length,
    excludedCount: questions.length - exportable.length,
  );
}

/// Builds one PDF spanning [questions], which may come from multiple
/// quizzes/lectures. Same exclusion behavior as
/// [exportReviewQuestionsToAnki].
Future<AggregateExportResult<Uint8List>> buildReviewDeckPdf(
  List<ReviewQuestion> questions, {
  required String deckName,
  required QuizPdfVariant variant,
  ShelfServerResolver? resolveShelfServer,
}) async {
  final exportable = _filterExportable(questions);
  final shelfCache = <String, (int?, String?)>{};

  // Images are resolved up front (the pdf package's build callback isn't
  // async), same pattern as the single-quiz PDF builder.
  final imagesByQuestionId = <String, Uint8List>{};
  for (final rq in exportable) {
    final bytes = await _resolveImage(rq, shelfCache, resolveShelfServer);
    if (bytes != null) imagesByQuestionId[rq.question.id] = bytes;
  }

  final regularFont =
      await loadPdfFont('assets/fonts/NotoNaskhArabic-Regular.ttf');
  final boldFont = await loadPdfFont('assets/fonts/NotoNaskhArabic-Bold.ttf');
  final generatedAt = DateTime.now();

  // No single Quiz spans an aggregate deck, so fall back to the first
  // exportable question's own direction for the deck-name header — same
  // 'rtl' fallback Quiz.questionDirection uses elsewhere.
  final headerDir = toPdfDirection(_parseDirection(exportable.isNotEmpty
      ? (exportable.first.question.questionDirectionOverride ??
          exportable.first.quizQuestionDirection)
      : 'rtl'));

  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
      header: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Directionality(
                textDirection: headerDir,
                child: pw.Text(
                  deckName.isNotEmpty ? deckName : 'Review Deck',
                  style: pw.TextStyle(
                      fontSize: 16, fontWeight: pw.FontWeight.bold),
                ),
              ),
              pw.Text(
                variant == QuizPdfVariant.solved
                    ? 'Answer Key'
                    : 'Practice Sheet',
                style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
              ),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'SecurePlayer • ${generatedAt.day}/${generatedAt.month}/${generatedAt.year}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey500),
          ),
          pw.Divider(height: 16),
        ],
      ),
      build: (context) => [
        for (var i = 0; i < exportable.length; i++)
          _buildAggregateQuestion(
              exportable[i], i, variant, imagesByQuestionId),
      ],
    ),
  );

  final bytes = await doc.save();
  return AggregateExportResult(
    data: bytes,
    includedCount: exportable.length,
    excludedCount: questions.length - exportable.length,
  );
}

ui.TextDirection _parseDirection(String value) =>
    value == 'ltr' ? ui.TextDirection.ltr : ui.TextDirection.rtl;

pw.Widget _buildAggregateQuestion(
  ReviewQuestion rq,
  int index,
  QuizPdfVariant variant,
  Map<String, Uint8List> imagesByQuestionId,
) {
  final questionDir = toPdfDirection(_parseDirection(
      rq.question.questionDirectionOverride ?? rq.quizQuestionDirection));
  final explanationDir = toPdfDirection(_parseDirection(
      rq.question.explanationDirectionOverride ?? rq.quizExplanationDirection));

  return buildQuestionPdfBlock(
    question: rq.question,
    index: index,
    variant: variant,
    questionDir: questionDir,
    explanationDir: explanationDir,
    imageBytes: imagesByQuestionId[rq.question.id],
  );
}
