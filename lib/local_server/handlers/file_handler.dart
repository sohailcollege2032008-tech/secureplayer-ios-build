import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import '../decryption/aes_decryptor.dart';

/// GET /file/:lectureId/:fileId/:filename
/// Reads an AES-128-CBC encrypted file from the sandbox, decrypts in memory,
/// and returns the raw bytes. Never writes plaintext to disk.
Future<Response> fileHandler(
  Request request,
  String lectureId,
  String fileId,
  String filename,
  String keyHex,
  Map<String, String> fileIvMap,
  String appDocPath,
) async {
  try {
    if (_hasPathTraversal(filename) ||
        _hasPathTraversal(fileId) ||
        _hasPathTraversal(lectureId)) {
      return Response.forbidden('Invalid path');
    }

    final ivHex = fileIvMap[fileId];

    // Primary path: files/{fileId} (standard layout)
    // Fallback: {fileId} at course root (older imports where flutter_archive
    // skipped creating the files/ subdirectory on some Android versions)
    final primaryPath = '$appDocPath/courses/$lectureId/files/$fileId';
    final fallbackPath = '$appDocPath/courses/$lectureId/$fileId';
    final file = File(primaryPath).existsSync()
        ? File(primaryPath)
        : File(fallbackPath).existsSync()
            ? File(fallbackPath)
            : null;
    if (file == null) {
      return Response.notFound('File not found: $filename');
    }

    final Uint8List plaintext;
    if (ivHex == null) {
      // Legacy .sec (pre-encryption) — files stored unencrypted, serve directly
      plaintext = await file.readAsBytes();
    } else {
      final encryptedBytes = await file.readAsBytes();
      final key = AesDecryptor.hexToBytes(keyHex);
      final iv = AesDecryptor.hexToBytes(ivHex);
      plaintext = await Isolate.run(() => AesDecryptor.decrypt(
            encryptedBytes: encryptedBytes,
            key: key,
            iv: iv,
            segmentName: filename,
          ));
    }

    return Response.ok(
      plaintext,
      headers: {
        'Content-Type': _mimeFor(filename),
        'Content-Length': '${plaintext.length}',
        'Cache-Control': 'no-store',
      },
    );
  } on FileSystemException {
    return Response.notFound('File missing: $filename');
  } catch (e) {
    return Response.internalServerError(body: 'File decrypt error: $e');
  }
}

bool _hasPathTraversal(String s) =>
    s.contains('/') || s.contains('\\') || s.contains('..');

String _mimeFor(String filename) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'application/octet-stream';
}
