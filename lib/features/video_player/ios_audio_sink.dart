import 'dart:async';

import 'package:flutter/services.dart';

import 'parallel_audio_sync.dart';

/// [ParallelAudioSink] over the native AVAudioPlayer channel
/// ("secureplayer/audio_sync", registered in AppDelegate.swift).
///
/// The sync engine reads position/playing SYNCHRONOUSLY on every tick, but
/// MethodChannel calls are async — so this sink keeps a cached copy of both,
/// refreshed by its own [Timer.periodic] poll loop (200ms, matching the
/// engine's drift budget). Commands (play/pause/seek/rate) go straight over
/// the channel.
class IosAudioSink implements ParallelAudioSink {
  IosAudioSink(
    this._channel, {
    this.playerId = 'default',
    this.refreshInterval = const Duration(milliseconds: 200),
  }) {
    _poll = Timer.periodic(refreshInterval, (_) => _refresh());
  }

  final MethodChannel _channel;
  final String playerId;
  final Duration refreshInterval;

  Timer? _poll;
  Duration _cachedPosition = Duration.zero;
  bool _cachedPlaying = false;
  bool _disposed = false;

  Map<String, dynamic> _args([Map<String, dynamic>? extra]) =>
      {'id': playerId, ...?extra};

  Future<void> _refresh() async {
    if (_disposed) return;
    try {
      final results = await _channel.invokeMethod<List<dynamic>>(
        'state',
        _args(),
      );
      if (results == null || results.length < 2) return;
      _cachedPosition = Duration(milliseconds: (results[0] as num).round());
      _cachedPlaying = results[1] as bool;
    } catch (_) {
      // A channel hiccup mid-flight is not worth taking the sync down.
    }
  }

  @override
  Future<void> play() => _channel.invokeMethod('play', _args());

  @override
  Future<void> pause() => _channel.invokeMethod('pause', _args());

  @override
  Future<void> seek(Duration position) => _channel.invokeMethod(
        'seek',
        _args({'position': position.inMilliseconds.toDouble()}),
      );

  @override
  Future<void> setRate(double rate) =>
      _channel.invokeMethod('setRate', _args({'rate': rate}));

  @override
  Duration get position => _cachedPosition;

  @override
  bool get playing => _cachedPlaying;

  @override
  Future<void> dispose() async {
    _disposed = true;
    _poll?.cancel();
    _poll = null;
    try {
      await _channel.invokeMethod('dispose', _args());
    } catch (_) {}
  }
}
