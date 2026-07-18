import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

Future<void>? _warmUpFuture;

/// Spawns one isolate and runs the real GCM/HKDF decrypt path on a dummy
/// buffer, paying the one-time isolate + pointycastle cold-start cost so the
/// first real segment request doesn't stall playback. Idempotent per process.
Future<void> warmUpSegmentDecryptor() {
  return _warmUpFuture ??= Isolate.run(() {
    final dummy = Uint8List(512);
    const keyHex = '000102030405060708090a0b0c0d0e0f';
    final wrapped = encryptSegmentOuter(dummy, keyHex, 'warmup-device');
    decryptSegmentOuter(wrapped, keyHex, 'warmup-device');
  }).catchError((_) {});
}

// Derives a 16-byte key from the course key using HKDF-SHA256 with a fixed info
// string, so the iv_map key is always distinct from the video decryption key.
Uint8List _deriveKey(Uint8List courseKey) {
  final info = utf8.encode('iv_map_encryption');
  final hkdf = HKDFKeyDerivator(SHA256Digest());
  hkdf.init(HkdfParameters(courseKey, 16, null, Uint8List.fromList(info)));
  final out = Uint8List(16);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

// Derives a 32-byte outer key from courseKey + deviceId.
// The device ID is used as HKDF salt so the derived key is unique per device.
Uint8List _deriveOuterKey(Uint8List courseKey, String deviceId) {
  final info = utf8.encode('seg_outer_v1');
  final salt = Uint8List.fromList(utf8.encode(deviceId));
  final hkdf = HKDFKeyDerivator(SHA256Digest());
  hkdf.init(HkdfParameters(courseKey, 32, salt, Uint8List.fromList(info)));
  final out = Uint8List(32);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

Uint8List _randomBytes(int n) {
  final rand = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => rand.nextInt(256)));
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Encrypts [ivMap] with AES-128-GCM using a key derived from [courseKeyHex].
/// Output format: [12-byte nonce][ciphertext + 16-byte GCM tag]
Uint8List encryptIvMap(Map<String, String> ivMap, String courseKeyHex) {
  final courseKey = _hexToBytes(courseKeyHex);
  final derivedKey = _deriveKey(courseKey);
  final nonce = _randomBytes(12);

  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(derivedKey), 128, nonce, Uint8List(0)),
    );

  final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(ivMap)));
  final ciphertext = cipher.process(plaintext);

  return Uint8List.fromList([...nonce, ...ciphertext]);
}

/// Decrypts [encrypted] produced by [encryptIvMap].
Map<String, String> decryptIvMap(Uint8List encrypted, String courseKeyHex) {
  final courseKey = _hexToBytes(courseKeyHex);
  final derivedKey = _deriveKey(courseKey);

  final nonce = encrypted.sublist(0, 12);
  final ciphertext = encrypted.sublist(12);

  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(KeyParameter(derivedKey), 128, nonce, Uint8List(0)),
    );

  final plaintext = cipher.process(ciphertext);
  return Map<String, String>.from(
    jsonDecode(utf8.decode(plaintext)) as Map,
  );
}

/// Wraps raw segment bytes with AES-256-GCM using a key derived from
/// [courseKeyHex] + [deviceId]. Called once per segment during import.
/// Output: [12-byte nonce][ciphertext + 16-byte GCM tag]
Uint8List encryptSegmentOuter(
    Uint8List bytes, String courseKeyHex, String deviceId) {
  final outerKey = _deriveOuterKey(_hexToBytes(courseKeyHex), deviceId);
  final nonce = _randomBytes(12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
        true, AEADParameters(KeyParameter(outerKey), 128, nonce, Uint8List(0)));
  final ciphertext = cipher.process(bytes);
  return Uint8List.fromList([...nonce, ...ciphertext]);
}

/// Strips the outer AES-256-GCM layer added by [encryptSegmentOuter].
/// Called in the segment handler before the inner AES-128-CBC decryption.
Uint8List decryptSegmentOuter(
    Uint8List bytes, String courseKeyHex, String deviceId) {
  final outerKey = _deriveOuterKey(_hexToBytes(courseKeyHex), deviceId);
  final nonce = bytes.sublist(0, 12);
  final ciphertext = bytes.sublist(12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false,
        AEADParameters(KeyParameter(outerKey), 128, nonce, Uint8List(0)));
  return cipher.process(ciphertext);
}
