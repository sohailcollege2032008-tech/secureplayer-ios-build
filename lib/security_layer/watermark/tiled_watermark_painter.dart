import 'dart:math';
import 'package:flutter/material.dart';

class TiledWatermarkPainter extends CustomPainter {
  final String text;
  final double angle; // angle in radians
  final double opacity;
  final double fontSize;

  TiledWatermarkPainter({
    required this.text,
    this.angle = -pi / 6, // -30 degrees
    this.opacity = 0.15, // visible on white PDF, faint enough to read content
    this.fontSize = 14,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final displayText = text.isNotEmpty ? text : 'SECURE PLAYER';

    // fontSize is a fixed config value, but watermark text (often
    // "name - phone - email") varies a lot in length. At a fixed size, a
    // long email would render wider than the page and get clipped at the
    // canvas edge, showing only part of it. Measure the text at the
    // configured size first, then scale the font down (never up) so the
    // whole string always fits within a comfortable fraction of the page
    // width — matching what BoldGhostWatermarkPainter already does for its
    // own mode.
    const targetWidthFraction = 0.42;
    final double targetMaxWidth = size.width * targetWidthFraction;

    double effectiveFontSize = fontSize;
    final probePainter = TextPainter(
      text: TextSpan(
        text: displayText,
        style: TextStyle(fontSize: fontSize, letterSpacing: 0.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (probePainter.width > targetMaxWidth && probePainter.width > 0) {
      effectiveFontSize =
          (fontSize * targetMaxWidth / probePainter.width).clamp(6.0, fontSize);
    }

    final textSpan = TextSpan(
      text: displayText,
      style: TextStyle(
        color: Colors.black.withValues(alpha: opacity),
        fontSize: effectiveFontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    final double textWidth = textPainter.width;
    final double textHeight = textPainter.height;

    // Calculate diagonal of canvas to ensure coverage when rotated
    final double maxDim =
        sqrt(size.width * size.width + size.height * size.height);

    canvas.save();
    // Rotate around the center of the canvas
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(angle);

    // Spacing between copies of the text (scaled by textWidth to prevent rotated overlap)
    final double xSpacing = textWidth + 140;
    final double ySpacing = textHeight + 110 + (textWidth * 0.18);

    final int xCount = (maxDim / xSpacing).ceil() + 2;
    final int yCount = (maxDim / ySpacing).ceil() + 2;

    final double startX = -maxDim / 2;
    final double startY = -maxDim / 2;

    for (int i = -xCount; i <= xCount; i++) {
      for (int j = -yCount; j <= yCount; j++) {
        // Shift alternate rows for staggered brick pattern
        final double xOffset = (j % 2 == 0) ? 0.0 : (xSpacing / 2);
        final double x = startX + i * xSpacing + xOffset;
        final double y = startY + j * ySpacing;

        textPainter.paint(canvas, Offset(x, y));
      }
    }

    canvas.restore();

    // Dispose painters to free native resources
    probePainter.dispose();
    textPainter.dispose();
  }

  @override
  bool shouldRepaint(covariant TiledWatermarkPainter oldDelegate) {
    return oldDelegate.text != text ||
        oldDelegate.angle != angle ||
        oldDelegate.opacity != opacity ||
        oldDelegate.fontSize != fontSize;
  }
}
