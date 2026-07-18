import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../core/errors/app_exception.dart';

class AesDecryptor {
  /// Decrypts AES-128-CBC data produced by FFmpeg.
  /// Uses raw CBC block-by-block decryption + manual PKCS7 strip to avoid
  /// PointyCastle's strict PaddedBlockCipherImpl validation, which throws
  /// InvalidCipherTextException on any padding edge case and produces a
  /// dropped TCP connection that causes ExoPlayer to hang indefinitely.
  static Uint8List decrypt({
    required Uint8List encryptedBytes,
    required Uint8List key,
    required Uint8List iv,
    required String segmentName,
  }) {
    assert(key.length == 16, 'AES key must be 16 bytes');
    assert(iv.length == 16, 'IV must be 16 bytes');

    if (encryptedBytes.isEmpty || encryptedBytes.length % 16 != 0) {
      throw DecryptionException(
        'Segment "$segmentName" size ${encryptedBytes.length} is not block-aligned',
      );
    }

    try {
      final cipher = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), iv));

      final output = Uint8List(encryptedBytes.length);
      for (var offset = 0; offset < encryptedBytes.length; offset += 16) {
        cipher.processBlock(encryptedBytes, offset, output, offset);
      }

      // Manual PKCS7 strip — avoids strict PointyCastle validation
      final padLen = output.last;
      if (padLen >= 1 && padLen <= 16) {
        return Uint8List.sublistView(output, 0, output.length - padLen);
      }
      return output;
    } catch (e) {
      throw DecryptionException('Failed to decrypt "$segmentName": $e');
    }
  }

  /// Parses a 32-char hex string to a 16-byte Uint8List (AES-128 key or IV).
  static Uint8List hexToBytes(String hex) {
    final cleaned = hex.trim().toLowerCase();
    if (cleaned.length != 32) {
      throw DecryptionException(
        'Hex must be 32 characters, got ${cleaned.length}: $cleaned',
      );
    }
    return Uint8List.fromList(
      List.generate(
        16,
        (i) => int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
  }
}
