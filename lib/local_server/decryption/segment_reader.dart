import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class SegmentReader {
  /// Reads the encrypted .ts file bytes from the sandbox.
  /// [appDocPath] is pre-computed at server start — avoids an async
  /// getApplicationSupportDirectory() call on every segment request.
  static Future<Uint8List> readEncryptedSegment({
    required String appDocPath,
    required String courseId,
    required String fileName,
  }) async {
    final path = '$appDocPath/courses/$courseId/segments/$fileName';
    final file = File(path);

    if (!await file.exists()) {
      throw FileSystemException('Segment file not found', path);
    }

    return file.readAsBytes();
  }

  static Future<String> coursePath(String courseId) async {
    final appDir = await getApplicationSupportDirectory();
    return '${appDir.path}/courses/$courseId';
  }
}
