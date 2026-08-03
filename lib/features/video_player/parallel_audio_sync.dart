import 'dart:async';

/// A secondary audio player that can follow play/pause/seek/rate commands.
///
/// Kept as an interface so [ParallelAudioSync] is pure logic with zero
/// media_kit/AVFoundation dependency — fully unit-testable with a fake.
abstract class ParallelAudioSink {
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);

  Duration get position;
  bool get playing;
  Future<void> dispose();
}

/// Drives a secondary audio player in lock-step with the video playhead.
///
/// The video is the master clock; the audio only ever follows:
///  - video plays  -> audio plays (after snapping to the video position)
///  - video pauses -> audio pauses
///  - drift > [driftThreshold] while playing -> audio re-seeks to video
///  - video rate != audio rate -> rate mirrored
///  - video ends  -> the video's own playing flag flips to false, which is
///    the pause branch above, so the audio stops with it.
///
/// Call [onVideoTick] from wherever the video reports state (its position
/// stream and/or the shared control helpers). The tick is idempotent and
/// cheap (a few comparisons), so calling it from several places is fine.
class ParallelAudioSync {
  ParallelAudioSync(this.audio);

  static const Duration driftThreshold = Duration(milliseconds: 200);

  final ParallelAudioSink audio;

  bool _audioStarted = false;
  double _lastVideoRate = 1.0;

  /// True after the first tick arrived, regardless of state.
  bool get hasStarted => _audioStarted;

  /// Called by the video player on every state report.
  void onVideoTick({
    required Duration videoPosition,
    required bool videoPlaying,
    required double videoRate,
  }) {
    _audioStarted = true;

    if (videoPlaying) {
      if (!audio.playing) {
        // Resume path: the user may have seeked while paused, so snap the
        // audio to the video position BEFORE starting it — otherwise the
        // audio resumes from wherever it last paused, and the drift check
        // below (which only runs while playing) would correct it with an
        // audible jump mid-sentence.
        if ((audio.position - videoPosition).abs() > driftThreshold) {
          unawaited(audio.seek(videoPosition));
        }
        unawaited(audio.play());
      } else {
        final drift = (audio.position - videoPosition).abs();
        if (drift > driftThreshold) {
          unawaited(audio.seek(videoPosition));
        }
        if (videoRate != _lastVideoRate) {
          unawaited(audio.setRate(videoRate));
        }
      }
    } else {
      if (audio.playing) {
        unawaited(audio.pause());
      }
    }

    _lastVideoRate = videoRate;
  }

  /// Hard control: the user explicitly seeked the video. Mirrors the seek to
  /// the audio immediately (even while paused, so resume starts in sync).
  void onVideoSeek(Duration videoPosition, {required bool videoPlaying}) {
    unawaited(audio.seek(videoPosition));
    if (videoPlaying && !audio.playing) {
      unawaited(audio.play());
    }
  }
}
