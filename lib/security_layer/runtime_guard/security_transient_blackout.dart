import 'package:flutter/material.dart';

/// Brief full-screen blackout shown while the runtime guard re-verifies
/// after a transient signal (window focus lost, HDMI connected, screen
/// recording started). Self-clears the instant the recheck comes back
/// clean — typically well under a second. Generalizes the pattern
/// VideoPlayerScreen used to implement only for itself (HDMI/recording)
/// into something every protected screen shares.
class SecurityTransientBlackout extends StatelessWidget {
  const SecurityTransientBlackout({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Text(
          'Content paused for security.',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}
