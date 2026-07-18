import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/models/course_metadata.dart';

/// Renders 3 semi-transparent watermarks simultaneously at independently
/// randomised positions. Each mark repositions every 10 seconds on a different
/// timer phase so they never all move at the same instant, making it harder to
/// cleanly inpaint all three in post-processing.
///
/// Physical-camera defence: high-contrast shadow + 60% opacity ensures the text
/// is visible even against dark or bright backgrounds. Slight rotation (+/-8°)
/// makes automatic OCR-removal tools less effective.
class WatermarkOverlay extends StatefulWidget {
  const WatermarkOverlay({
    super.key,
    required this.studentName,
    required this.phoneNumber,
    required this.child,
    this.studentEmail = '',
    this.config = WatermarkConfig.off,
  });

  final String studentName;
  final String phoneNumber;
  final String studentEmail;
  final WatermarkConfig config;
  final Widget child;

  @override
  State<WatermarkOverlay> createState() => _WatermarkOverlayState();
}

class _WatermarkOverlayState extends State<WatermarkOverlay> {
  static const _count = 3;

  // Each mark has its own position + rotation + opacity + timer phase offset.
  final List<_MarkState> _marks = [];
  final List<Timer> _timers = [];

  static _MarkState _markForIndex(int i, Random rng) {
    switch (i) {
      case 0:  return _MarkState.topLeft(rng);
      case 1:  return _MarkState.center(rng);
      default: return _MarkState.bottomRight(rng);
    }
  }

  @override
  void initState() {
    super.initState();
    final rng = Random(DateTime.now().millisecondsSinceEpoch);
    for (var i = 0; i < _count; i++) {
      _marks.add(_markForIndex(i, rng));
    }

    // Stagger the timers so the marks reposition at different moments.
    for (var i = 0; i < _count; i++) {
      final phaseDelay = Duration(seconds: i * 3); // 0s, 3s, 6s offsets
      Future.delayed(phaseDelay, () {
        if (!mounted) return;
        _timers.add(
          Timer.periodic(const Duration(seconds: 10), (_) {
            if (!mounted) return;
            setState(() {
              _marks[i] = _markForIndex(
                i,
                Random(DateTime.now().millisecondsSinceEpoch + i * 1000),
              );
            });
          }),
        );
      });
    }
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  String _buildText() {
    // When config is off (video watermark legacy path), show name+phone always.
    if (!widget.config.enabled) {
      return '${widget.studentName}\n${widget.phoneNumber}';
    }
    final parts = <String>[
      if (widget.config.showName && widget.studentName.isNotEmpty) widget.studentName,
      if (widget.config.showEmail && widget.studentEmail.isNotEmpty) widget.studentEmail,
      if (widget.config.showPhone && widget.phoneNumber.isNotEmpty) widget.phoneNumber,
    ];
    return parts.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final text = _buildText();
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (_, constraints) => Stack(
                children: [
                  for (var i = 0; i < _count; i++)
                    Positioned(
                      left: constraints.maxWidth * _marks[i].leftFraction,
                      top: constraints.maxHeight * _marks[i].topFraction,
                      child: Transform.rotate(
                        angle: _marks[i].rotationRad,
                        child: _WatermarkText(
                          text: text,
                          opacity: _marks[i].opacity,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MarkState {
  const _MarkState({
    required this.leftFraction,
    required this.topFraction,
    required this.rotationRad,
    required this.opacity,
  });

  final double leftFraction;
  final double topFraction;
  final double rotationRad;
  final double opacity;

  // Shared rotation + opacity logic.
  static double _rotation(Random rng) =>
      (rng.nextDouble() * 16 - 8) * (pi / 180);
  static double _opacity(Random rng) => 0.55 + rng.nextDouble() * 0.15;

  // Mark 0 — top-left quadrant: impossible to crop out without losing most content.
  factory _MarkState.topLeft(Random rng) => _MarkState(
        leftFraction: rng.nextDouble() * 0.25 + 0.04,   // 4%–29% from left
        topFraction: rng.nextDouble() * 0.25 + 0.04,    // 4%–29% from top
        rotationRad: _rotation(rng),
        opacity: _opacity(rng),
      );

  // Mark 1 — guaranteed center zone: anchors identification even after edge cropping.
  factory _MarkState.center(Random rng) => _MarkState(
        leftFraction: rng.nextDouble() * 0.20 + 0.35,   // 35%–55% from left
        topFraction: rng.nextDouble() * 0.20 + 0.38,    // 38%–58% from top
        rotationRad: _rotation(rng),
        opacity: _opacity(rng),
      );

  // Mark 2 — bottom-right quadrant: completes the coverage triangle.
  factory _MarkState.bottomRight(Random rng) => _MarkState(
        leftFraction: rng.nextDouble() * 0.25 + 0.45,   // 45%–70% from left
        topFraction: rng.nextDouble() * 0.25 + 0.55,    // 55%–80% from top
        rotationRad: _rotation(rng),
        opacity: _opacity(rng),
      );
}

class _WatermarkText extends StatelessWidget {
  const _WatermarkText({required this.text, required this.opacity});
  final String text;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: opacity),
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        shadows: [
          // Dark shadow makes text readable on bright backgrounds.
          Shadow(
            color: Colors.black.withValues(alpha: 0.75),
            blurRadius: 3,
            offset: const Offset(1, 1),
          ),
          // Second shadow gives contrast on dark backgrounds.
          Shadow(
            color: Colors.white.withValues(alpha: 0.25),
            blurRadius: 3,
            offset: const Offset(-1, -1),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
