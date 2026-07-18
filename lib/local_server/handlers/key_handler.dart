import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import '../decryption/aes_decryptor.dart';

/// GET /key/:lectureId
/// Returns the raw 16-byte AES-128 key so the HLS player can decrypt segments.
/// The player (better_player) fetches this URL because the playlist's
/// #EXT-X-KEY:URI points here.
Response keyHandler(String lectureId, String keyHex) {
  try {
    final keyBytes = AesDecryptor.hexToBytes(keyHex);
    return Response.ok(
      Uint8List.fromList(keyBytes),
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${keyBytes.length}',
        'Cache-Control': 'no-store',
      },
    );
  } catch (e) {
    return Response.internalServerError(body: 'Key error: $e');
  }
}
