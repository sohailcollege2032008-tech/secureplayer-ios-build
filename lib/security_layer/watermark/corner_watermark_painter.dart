import 'dart:math' show max;
import 'package:flutter/material.dart';

/// Corner watermark — mirrors Python _apply_corner_watermarks().
///
/// Draws the watermark text at 3 positions: top-left, center, bottom-right.
/// Font auto-shrinks until the text fits within the page width.
/// Meant to be stacked on top of BoldGhostWatermarkPainter for PDF pages.
class CornerWatermarkPainter extends CustomPainter {
  const CornerWatermarkPainter({
    required this.text,
    this.opacity = 0.216,
    this.color = const Color(0xFF464646),
  });

  final String text;
  final double opacity;
  final Color color;

  List<String> get _lines =>
      text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  @override
  void paint(Canvas canvas, Size size) {
    final lines = _lines.isEmpty ? ['SECURE PLAYER'] : _lines;
    final margin = max(12.0, size.width / 80);
    final maxTextWidth = size.width - 2 * margin;

    // Auto-size font: start at w/45, shrink until all lines fit
    double fontSize = size.width / 45;
    const floor = 8.0;

    bool fits(double fs) {
      for (final line in lines) {
        final tp = TextPainter(
          text: TextSpan(
            text: line,
            style: TextStyle(fontSize: fs, fontWeight: FontWeight.w600),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: double.infinity);
        if (tp.width > maxTextWidth) return false;
        tp.dispose();
      }
      return true;
    }

    while (!fits(fontSize) && fontSize > floor) {
      fontSize -= 1;
    }

    final mainStyle = TextStyle(
      color: color.withValues(alpha: opacity),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );
    final shadowStyle = TextStyle(
      color: Colors.black.withValues(alpha: 55 / 255),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );

    // Measure each line
    final mainPainters = <TextPainter>[];
    final shadowPainters = <TextPainter>[];
    double blockW = 0;
    double blockH = 0;
    const lineGap = 2.0;

    for (final line in lines) {
      final mp = TextPainter(
        text: TextSpan(text: line, style: mainStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final sp = TextPainter(
        text: TextSpan(text: line, style: shadowStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      mainPainters.add(mp);
      shadowPainters.add(sp);
      if (mp.width > blockW) blockW = mp.width;
      blockH += mp.height + lineGap;
    }
    blockH -= lineGap; // remove trailing gap

    void drawBlock(Canvas canvas, double left, double top) {
      double y = top;
      for (int i = 0; i < mainPainters.length; i++) {
        final mp = mainPainters[i];
        final sp = shadowPainters[i];
        sp.paint(canvas, Offset(left + 2, y + 2));
        mp.paint(canvas, Offset(left, y));
        y += mp.height + lineGap;
      }
    }

    // Top-left
    drawBlock(canvas, margin, margin);

    // Center
    drawBlock(
      canvas,
      (size.width - blockW) / 2,
      (size.height - blockH) / 2,
    );

    // Bottom-right
    drawBlock(
      canvas,
      size.width - blockW - margin,
      size.height - blockH - margin,
    );

    for (final p in mainPainters) { p.dispose(); }
    for (final p in shadowPainters) { p.dispose(); }
  }

  @override
  bool shouldRepaint(covariant CornerWatermarkPainter old) =>
      old.text != text || old.opacity != opacity || old.color != color;
}
