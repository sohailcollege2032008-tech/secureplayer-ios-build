import 'dart:math' show sqrt, pi, cos, sin;
import 'package:flutter/material.dart';

/// Bold-ghost diagonal watermark — mirrors the Python BoldGhostWatermarkPainter.
///
/// Draws N large semi-transparent stamps diagonally across the page.
/// Stamps are spaced by (blockH + stampGap) in the pre-rotation frame,
/// which guarantees zero overlap even after rotation (rotation is an isometry).
///
/// Font size is calculated dynamically from the canvas diagonal so exactly
/// ~3 stamps fit regardless of page dimensions.
class BoldGhostWatermarkPainter extends CustomPainter {
  const BoldGhostWatermarkPainter({
    required this.text,
    this.angle = -35 * (pi / 180),
    this.opacity = 0.165,
    this.color = const Color(0xFF4B4B4B),
  });

  final String text;
  final double angle;   // radians — negative = tilts bottom-right to top-left
  final double opacity;
  final Color color;

  // Lines are separated by \n (same convention as TiledWatermarkPainter receives).
  List<String> get _lines =>
      text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  @override
  void paint(Canvas canvas, Size size) {
    final lines = _lines.isEmpty ? ['SECURE PLAYER'] : _lines;
    final n = lines.length;

    // ── 1. Calculate font size for ~3 non-overlapping stamps ─────────────────
    final diagonal = sqrt(size.width * size.width + size.height * size.height);
    // unit_factor mirrors Python: n*1.25 + (n-1)*0.28 + 0.8
    final unitFactor = n * 1.25 + (n - 1) * 0.28 + 0.8;
    double fontSize = (diagonal * 0.90 / (3.0 * unitFactor))
        .clamp(40.0, size.width / 4.0);

    // The geometry-only size above ignores actual string length — a long
    // line (e.g. a full email address) can render wider than the canvas at
    // this size and get clipped at the edge, showing only a fragment of the
    // text (e.g. just the last few characters). Measure the widest line at
    // this font size and, accounting for the diagonal rotation's footprint,
    // scale down (never up) so the full text always stays within the canvas.
    final probeStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );
    double maxLineWidth = 0;
    for (final line in lines) {
      final probe = TextPainter(
        text: TextSpan(text: line, style: probeStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      if (probe.width > maxLineWidth) maxLineWidth = probe.width;
      probe.dispose();
    }
    final cosA = cos(angle).abs();
    final sinA = sin(angle).abs();
    final approxBlockHeight = fontSize * 1.2 * n;
    final rotatedFootprint = maxLineWidth * cosA + approxBlockHeight * sinA;
    final maxAllowed = size.width * 0.9;
    if (rotatedFootprint > maxAllowed && rotatedFootprint > 0) {
      fontSize = (fontSize * maxAllowed / rotatedFootprint).clamp(16.0, fontSize);
    }

    final paintStyle = TextStyle(
      color: color.withValues(alpha: opacity),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );
    final shadowStyle = TextStyle(
      color: Colors.black.withValues(alpha: opacity * 0.45),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );

    // ── 2. Measure each line ──────────────────────────────────────────────────
    final painters = <TextPainter>[];
    final shadowPainters = <TextPainter>[];
    final lineHeights = <double>[];

    for (final line in lines) {
      final tp = TextPainter(
        text: TextSpan(text: line, style: paintStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final ts = TextPainter(
        text: TextSpan(text: line, style: shadowStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painters.add(tp);
      shadowPainters.add(ts);
      lineHeights.add(tp.height);
    }

    final lineGap = fontSize * 0.28;
    final blockH = lineHeights.fold(0.0, (a, h) => a + h) + lineGap * (n - 1);
    // ── 3. Draw: one stamp centered — corners handled by CornerWatermarkPainter ─
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(angle);

    double y = -blockH / 2;
    for (int i = 0; i < painters.length; i++) {
      final tp = painters[i];
      final ts = shadowPainters[i];
      final x = -tp.width / 2;
      ts.paint(canvas, Offset(x + 2, y + 2));
      tp.paint(canvas, Offset(x, y));
      y += lineHeights[i] + (i < n - 1 ? lineGap : 0);
    }

    canvas.restore();

    // Dispose painters to free native resources
    for (final tp in painters) { tp.dispose(); }
    for (final ts in shadowPainters) { ts.dispose(); }
  }

  @override
  bool shouldRepaint(covariant BoldGhostWatermarkPainter old) =>
      old.text != text ||
      old.angle != angle ||
      old.opacity != opacity ||
      old.color != color;
}
