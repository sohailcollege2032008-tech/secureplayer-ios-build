import 'dart:typed_data';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/quiz.dart';

/// Two flavors of quiz PDF: [unsolved] is a blank practice sheet (question +
/// options only), [solved] additionally highlights the correct option and
/// shows the explanation — an answer key.
enum QuizPdfVariant { unsolved, solved }

/// Builds a quiz PDF using native `pdf`-package text drawing (validated
/// against the app's Arabic/RTL content in a throwaway spike — the package's
/// default settings already handle Arabic contextual joining and bidi
/// reordering correctly with a bundled Naskh font, no custom reshaping or
/// build-time flags needed).
///
/// Direction is resolved per-question via [Quiz.effectiveQuestionDirection]/
/// [Quiz.effectiveExplanationDirection] — the same logic
/// `QuizQuestionBody` already applies on screen — converted from Flutter's
/// `dart:ui` TextDirection to the pdf package's own TextDirection enum.
Future<Uint8List> buildQuizPdf(
  Quiz quiz, {
  required QuizPdfVariant variant,
  Map<String, Uint8List> imagesByQuestionId = const {},
}) async {
  final regularFont =
      await loadPdfFont('assets/fonts/NotoNaskhArabic-Regular.ttf');
  final boldFont = await loadPdfFont('assets/fonts/NotoNaskhArabic-Bold.ttf');

  final doc = pw.Document();
  final generatedAt = DateTime.now();

  final titleDir =
      quiz.questionDirection == 'rtl' ? pw.TextDirection.rtl : pw.TextDirection.ltr;

  doc.addPage(
    pw.MultiPage(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
      header: (context) => _buildHeader(quiz.title, variant, generatedAt, titleDir),
      build: (context) => [
        for (var i = 0; i < quiz.questions.length; i++)
          buildQuestionPdfBlock(
            question: quiz.questions[i],
            index: i,
            variant: variant,
            questionDir: toPdfDirection(
                quiz.effectiveQuestionDirection(quiz.questions[i])),
            explanationDir: toPdfDirection(
                quiz.effectiveExplanationDirection(quiz.questions[i])),
            imageBytes: imagesByQuestionId[quiz.questions[i].id],
          ),
      ],
    ),
  );

  return doc.save();
}

/// Loads a bundled PDF font by asset path — shared by the single-quiz and
/// aggregate (review-deck) PDF builders.
Future<pw.Font> loadPdfFont(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  return pw.Font.ttf(data);
}

/// Converts Flutter's `dart:ui` TextDirection (what
/// [Quiz.effectiveQuestionDirection]/[Quiz.effectiveExplanationDirection]
/// return) to the pdf package's own TextDirection enum.
pw.TextDirection toPdfDirection(ui.TextDirection direction) =>
    direction == ui.TextDirection.rtl
        ? pw.TextDirection.rtl
        : pw.TextDirection.ltr;

pw.Widget _buildHeader(
  String title,
  QuizPdfVariant variant,
  DateTime generatedAt,
  pw.TextDirection titleDir,
) {
  final variantLabel =
      variant == QuizPdfVariant.solved ? 'Answer Key' : 'Practice Sheet';
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Directionality(
            textDirection: titleDir,
            child: pw.Text(
              title.isNotEmpty ? title : 'Quiz',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Text(variantLabel,
              style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        ],
      ),
      pw.SizedBox(height: 4),
      pw.Text(
        'SecurePlayer • ${generatedAt.day}/${generatedAt.month}/${generatedAt.year}',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey500),
      ),
      pw.Divider(height: 16),
    ],
  );
}

/// Renders one question + options (+ image, + answer/explanation when
/// [variant] is solved) as a PDF block. Shared by the single-quiz builder
/// above and the aggregate review-deck builder
/// (`lib/features/export/review_deck_export.dart`), which has no single
/// [Quiz] object to read direction from — both resolve direction to a plain
/// [pw.TextDirection] before calling this.
pw.Widget buildQuestionPdfBlock({
  required QuizQuestion question,
  required int index,
  required QuizPdfVariant variant,
  required pw.TextDirection questionDir,
  required pw.TextDirection explanationDir,
  Uint8List? imageBytes,
}) {
  final showAnswers = variant == QuizPdfVariant.solved;

  return pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 18),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Directionality(
          textDirection: questionDir,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // Kept as two separate Text widgets rather than one
              // interpolated string ('${index+1}. ${question.text}') — the
              // pdf package's bidi reordering mishandles a Latin numeral
              // prefix fused into the same run as RTL Arabic content
              // (confirmed empirically: pure-Arabic runs like the options
              // below render correctly, only this mixed-prefix line didn't).
              // A Row with pure single-direction Text children sidesteps
              // that entirely instead of relying on the reorderer.
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '${index + 1}.',
                    style:
                        pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
                  ),
                  pw.SizedBox(width: 4),
                  pw.Expanded(
                    child: pw.Text(
                      question.text,
                      style: pw.TextStyle(
                          fontSize: 12, fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                ],
              ),
              if (imageBytes != null) ...[
                pw.SizedBox(height: 8),
                pw.Center(
                  child: pw.Image(
                    pw.MemoryImage(imageBytes),
                    height: 160,
                    fit: pw.BoxFit.contain,
                  ),
                ),
              ],
              pw.SizedBox(height: 6),
              for (var i = 0; i < question.options.length; i++)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 3),
                  child: pw.Text(
                    '${String.fromCharCode(65 + i)}) ${question.options[i]}',
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: (showAnswers && i == question.correctIndex)
                          ? pw.FontWeight.bold
                          : pw.FontWeight.normal,
                      color: (showAnswers && i == question.correctIndex)
                          ? PdfColors.green800
                          : PdfColors.black,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (showAnswers && question.explanation.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          pw.Directionality(
            textDirection: explanationDir,
            child: pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Text(
                question.explanation,
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey800),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
