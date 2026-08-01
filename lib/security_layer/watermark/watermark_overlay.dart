import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/models/course_metadata.dart';

/// Renders the VIDEO watermark overlay (files use the CustomPaint painters,
/// not this widget — see tiled_watermark_painter.dart etc.).
///
/// Two styles, chosen per-lecture by the teacher in Studio
/// (WatermarkConfig.videoStyle):
///
/// 1. [VideoWatermarkStyle.tiled] (the classic): 3 semi-transparent marks at
///    independently randomised positions. Each mark repositions every 10
///    seconds on a different timer phase so they never all move at the same
///    instant, making it harder to cleanly inpaint all three in post.
/// 2. [VideoWatermarkStyle.animated]: ONE mark that drifts smoothly across
///    the whole frame — a wandering Lissajous path (incommensurate sine
///    frequencies + a slow secondary drift) so every region of the video is
///    covered over time, plus a gentle continuous rotation and a subtle
///    opacity pulse. Teleport-free by design: position/rotation/opacity are
///    continuous functions of time, so there is never a hard cut an
///    inpainting tool could key on.
///
/// Physical-camera defence (both styles): high-contrast shadow + ~60%
/// opacity ensures the text is visible even against dark or bright
/// backgrounds. Slight rotation makes automatic OCR-removal tools less
/// effective.
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

class _WatermarkOverlayState extends State<WatermarkOverlay>
    with SingleTickerProviderStateMixin {
  static const _count = 3;

  // ── Tiled style: per-mark state + staggered timers ──────────────────────
  final List<_MarkState> _marks = [];
  final List<Timer> _timers = [];

  // ── Animated style: one continuous drifting mark ────────────────────────
  AnimationController? _animCtrl;
  // Random phases per session so no two students see the same path.
  final double _phase1 = Random().nextDouble() * 2 * pi;
  final double _phase2 = Random().nextDouble() * 2 * pi;
  final double _phase3 = Random().nextDouble() * 2 * pi;
  final double _phase4 = Random().nextDouble() * 2 * pi;
  final double _phase5 = Random().nextDouble() * 2 * pi;
  final double _phase6 = Random().nextDouble() * 2 * pi;

  bool get _animated =>
      widget.config.videoStyle == VideoWatermarkStyle.animated;

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
    if (_animated) {
      _animCtrl = AnimationController(
        vsync: this,
        // One full wander cycle; the slow secondary-drift terms make the
        // path non-repeating, so coverage only improves over time.
        duration: const Duration(seconds: 26),
      )..repeat();
      return;
    }

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
    _animCtrl?.dispose();
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
              builder: (_, constraints) => _animated
                  ? _buildAnimatedMark(text)
                  : Stack(
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

  /// Single mark drifting on a smooth Lissajous path. Position, rotation and
  /// opacity are continuous functions of the animation clock — the mark
  /// glides, it never jumps.
  Widget _buildAnimatedMark(String text) {
    return AnimatedBuilder(
      animation: _animCtrl!,
      builder: (context, _) {
        final t = _animCtrl!.value * 2 * pi;
        // Main Lissajous terms (frequencies 1.0 / 1.7 — incommensurate, so
        // the path fills the frame instead of tracing a closed loop) plus a
        // slow secondary drift (0.23 / 0.19) that keeps the pattern from
        // repeating cycle-to-cycle.
        final x = (0.5 +
                0.46 * sin(t + _phase1) +
                0.04 * sin(t * 0.23 + _phase4))
            .clamp(0.02, 0.98);
        final y = (0.5 +
                0.46 * sin(t * 1.7 + _phase2) +
                0.04 * cos(t * 0.19 + _phase5))
            .clamp(0.02, 0.98);
        final angle = 0.12 * sin(t * 2.1 + _phase3); // ±~7°
        final opacity = (0.58 + 0.08 * sin(t * 1.3 + _phase6)).clamp(0.0, 1.0);

        return Align(
          alignment: Alignment(x * 2 - 1, y * 2 - 1),
          child: FractionalTranslation(
            // Centres the mark on the path point (Align positions its
            // top-left corner otherwise).
            translation: const Offset(-0.5, -0.5),
            child: Transform.rotate(
              angle: angle,
              child: _WatermarkText(text: text, opacity: opacity, fontSize: 15),
            ),
          ),
        );
      },
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
  const _WatermarkText({
    required this.text,
    required this.opacity,
    this.fontSize = 13,
  });

  final String text;
  final double opacity;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: opacity),
        fontSize: fontSize,
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
