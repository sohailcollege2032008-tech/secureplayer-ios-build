import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_player/features/video_player/parallel_audio_sync.dart';
import 'package:secure_player/local_server/decryption/aes_decryptor.dart';
import 'package:pointycastle/export.dart';

/// Records every command a real audio player would receive, and lets the
/// test script its position/playing state â€” the whole sync contract in a
/// fake, no media_kit needed.
class FakeAudioSink implements ParallelAudioSink {
  final List<String> commands = [];

  @override
  Duration position = Duration.zero;

  @override
  bool playing = false;
  double rate = 1.0;

  @override
  Future<void> play() async {
    commands.add('play');
    playing = true;
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    playing = false;
  }

  @override
  Future<void> seek(Duration p) async {
    commands.add('seek:${p.inMilliseconds}');
    position = p;
  }

  @override
  Future<void> setRate(double r) async {
    commands.add('rate:$r');
    rate = r;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('ParallelAudioSync', () {
    test('starts the audio when the video starts playing', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);

      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);

      expect(sink.commands, contains('play'));
      expect(sink.playing, isTrue);
    });

    test('pauses the audio when the video pauses', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);
      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);
      sink.commands.clear();

      sync.onVideoTick(videoPosition: const Duration(seconds: 5), videoPlaying: false, videoRate: 1.0);

      expect(sink.commands, contains('pause'));
      expect(sink.playing, isFalse);
    });

    test('does not touch a stopped audio when the video is stopped', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);

      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: false, videoRate: 1.0);

      expect(sink.commands, isEmpty);
    });

    test('corrects drift above the threshold while playing', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);
      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);
      sink.commands.clear();

      // Audio lagging 1s behind the video â†’ must re-seek.
      sink.position = const Duration(seconds: 9);
      sync.onVideoTick(videoPosition: const Duration(seconds: 10), videoPlaying: true, videoRate: 1.0);

      expect(sink.commands, contains('seek:10000'));
      expect(sink.position, const Duration(seconds: 10));
    });

    test('does not re-seek when drift is within the threshold', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);
      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);
      sink.commands.clear();

      sink.position = const Duration(milliseconds: 100);
      sync.onVideoTick(videoPosition: const Duration(milliseconds: 100), videoPlaying: true, videoRate: 1.0);

      expect(sink.commands.where((c) => c.startsWith('seek')), isEmpty);
    });

    test('mirrors the video playback rate', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);
      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);
      sink.commands.clear();

      sync.onVideoTick(videoPosition: const Duration(seconds: 1), videoPlaying: true, videoRate: 1.5);

      expect(sink.commands, contains('rate:1.5'));
      expect(sink.rate, 1.5);
    });

    test('snaps audio to the video position when resuming after a paused seek', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);
      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);
      sink.commands.clear();

      // Real flow: user pauses (tick pauses the audio), THEN seeks.
      sync.onVideoTick(videoPosition: const Duration(seconds: 28), videoPlaying: false, videoRate: 1.0);
      expect(sink.playing, isFalse);
      sink.commands.clear();

      // Seek while paused: audio follows even though it stays paused.
      sync.onVideoSeek(const Duration(seconds: 30), videoPlaying: false);
      expect(sink.commands, contains('seek:30000'));
      expect(sink.playing, isFalse);
      sink.commands.clear();

      // Resume: audio starts AT the video position, not from its old spot.
      sink.position = const Duration(seconds: 30);
      sync.onVideoTick(videoPosition: const Duration(seconds: 30), videoPlaying: true, videoRate: 1.0);
      expect(sink.commands, contains('play'));
      expect(sink.commands.where((c) => c.startsWith('seek')), isEmpty);
    });

    test('pauses the audio at end of video (playing flag flips false)', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);
      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);
      sink.commands.clear();

      sync.onVideoTick(videoPosition: const Duration(seconds: 60), videoPlaying: false, videoRate: 1.0);

      expect(sink.commands, contains('pause'));
      expect(sink.playing, isFalse);
    });

    test('seek during playback is mirrored immediately', () {
      final sink = FakeAudioSink();
      final sync = ParallelAudioSync(sink);
      sync.onVideoTick(videoPosition: Duration.zero, videoPlaying: true, videoRate: 1.0);
      sink.commands.clear();

      sync.onVideoSeek(const Duration(seconds: 42), videoPlaying: true);

      expect(sink.commands, contains('seek:42000'));
      expect(sink.position, const Duration(seconds: 42));
    });
  });

  group('AesDecryptor round-trip (packager-compatible scheme)', () {
    // Same scheme the Python packager uses: AES-128-CBC + PKCS7.
    test('decrypts what the packager-style encryptor produces', () {
      const keyHex = '00112233445566778899aabbccddeeff';
      const ivHex = 'ffeeddccbbaa99887766554433221100';
      final key = AesDecryptor.hexToBytes(keyHex);
      final iv = AesDecryptor.hexToBytes(ivHex);

      const plaintext =
          'parallel audio plaintext payload â€” must survive a full block '
          'boundary and PKCS7 padding exactly like the packager produces';
      final raw = Uint8List.fromList(utf8.encode(plaintext));

      final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
        ..init(
          true,
          PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
            ParametersWithIV(KeyParameter(key), iv),
            null,
          ),
        );
      final encrypted = cipher.process(raw);

      final decrypted = AesDecryptor.decrypt(
        encryptedBytes: encrypted,
        key: key,
        iv: iv,
        segmentName: 'test-audio',
      );

      expect(utf8.decode(decrypted), plaintext);
    });
  });
}
