import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import '../decryption/aes_decryptor.dart';
import '../decryption/iv_map_crypto.dart';
import '../decryption/segment_reader.dart';

/// GET /segment/:lectureId/:videoId/:fileName  (v2)
/// Strips the outer AES-256-GCM device-bound layer in a background isolate,
/// then returns the inner AES-128-CBC bytes for the HLS player to decrypt.
Future<Response> segmentHandlerV2(
  Request request,
  String lectureId,
  String videoId,
  String fileName,
  String keyHex,
  String deviceId,
  String appDocPath,
) async {
  try {
    if (_hasPathTraversal(fileName) ||
        _hasPathTraversal(lectureId) ||
        _hasPathTraversal(videoId)) {
      return Response.forbidden('Invalid segment name');
    }

    final segPath =
        '$appDocPath/courses/$lectureId/videos/$videoId/segments/$fileName';
    final segFile = File(segPath);
    if (!segFile.existsSync()) {
      return Response.notFound('Segment not found: $fileName');
    }

    final doubleEncryptedBytes = segFile.readAsBytesSync();

    // Run outer GCM decryption in a background isolate so the main Flutter
    // isolate (UI + server) stays responsive during concurrent segment requests.
    final innerCbcBytes = await Isolate.run(() {
      return decryptSegmentOuter(doubleEncryptedBytes, keyHex, deviceId);
    });

    return Response.ok(
      innerCbcBytes,
      headers: {
        'Content-Type': 'video/MP2T',
        'Content-Length': '${innerCbcBytes.length}',
        'Cache-Control': 'no-store',
      },
    );
  } on FileSystemException {
    return Response.notFound('Segment file missing: $fileName');
  } catch (e) {
    return Response.internalServerError(body: 'Segment error: $e');
  }
}

/// GET /segment/:courseId/:fileName  (v1 legacy)
/// Strips outer GCM + decrypts inner CBC. Used for v1 .sec files.
Future<Response> segmentHandlerV1(
  Request request,
  String courseId,
  String fileName,
  String keyHex,
  Map<String, String> ivMap,
  String appDocPath,
  String deviceId,
) async {
  try {
    if (_hasPathTraversal(fileName) || _hasPathTraversal(courseId)) {
      return Response.forbidden('Invalid segment name');
    }

    // 2. Per-segment IV (also acts as whitelist — rejects unknown filenames)
    final ivHex = ivMap[fileName];
    if (ivHex == null) {
      return Response.notFound('Unknown segment: $fileName');
    }

    // 3. Read double-encrypted bytes from sandbox
    final doubleEncryptedBytes = await SegmentReader.readEncryptedSegment(
      appDocPath: appDocPath,
      courseId: courseId,
      fileName: fileName,
    );

    // 4. Strip outer AES-256-GCM device-bound layer (added during import).
    //    Result is the original FFmpeg AES-128-CBC ciphertext.
    final encryptedBytes = decryptSegmentOuter(doubleEncryptedBytes, keyHex, deviceId);

    // 5. Decrypt inner AES-128-CBC in a background isolate so concurrent segment
    //    requests run in parallel instead of serializing on the main isolate.
    //    Uint8List is sendable across isolate boundaries with zero-copy transfer.
    final key = AesDecryptor.hexToBytes(keyHex);
    final iv = AesDecryptor.hexToBytes(ivHex);
    final Uint8List decryptedBytes = await Isolate.run(() {
      return AesDecryptor.decrypt(
        encryptedBytes: encryptedBytes,
        key: key,
        iv: iv,
        segmentName: fileName,
      );
    });

    return Response.ok(
      decryptedBytes,
      headers: {
        'Content-Type': 'video/MP2T',
        'Content-Length': '${decryptedBytes.length}',
        'Cache-Control': 'no-store',
      },
    );
  } on FileSystemException {
    return Response.notFound('Segment file missing: $fileName');
  } catch (e) {
    return Response.internalServerError(body: 'Segment error: $e');
  }
}

bool _hasPathTraversal(String name) =>
    name.contains('/') || name.contains('\\') || name.contains('..');
