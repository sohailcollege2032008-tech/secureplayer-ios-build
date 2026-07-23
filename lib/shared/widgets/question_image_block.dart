import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../app/theme.dart';

/// Question text, optionally preceded by its image (fetched in-memory from
/// the shelf server) with a loading placeholder while the image is still
/// being fetched. Shared by quiz-taking and SRS review, which show the same
/// question layout.
class QuestionTextWithImage extends StatelessWidget {
  const QuestionTextWithImage({
    super.key,
    required this.text,
    required this.hasImage,
    required this.imageBytes,
    this.textStyle,
  });

  final String text;
  final bool hasImage;
  final Uint8List? imageBytes;
  // Overrides the default style below (used by callers with dynamic
  // font-size/family settings, e.g. QuizQuestionBody). Null keeps the
  // original hardcoded look for callers that don't opt in.
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final textWidget = Text(
      text,
      style: textStyle ??
          const TextStyle(
            color: Colors.white,
            fontSize: 17,
            height: 1.5,
            fontWeight: FontWeight.w500,
          ),
    );
    if (!hasImage) return textWidget;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            // Bounds the image so a high-res photo scales down to fit
            // instead of rendering at native resolution and pushing the
            // answer options off-screen. BoxFit.contain still preserves
            // aspect ratio within this box; small images simply center.
            constraints: const BoxConstraints(maxHeight: 240),
            child: imageBytes != null
                ? Image.memory(imageBytes!, fit: BoxFit.contain)
                : Container(
                    height: 160,
                    color: Colors.white.withValues(alpha: 0.04),
                    child: const Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.primary, strokeWidth: 2),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        textWidget,
      ],
    );
  }
}
