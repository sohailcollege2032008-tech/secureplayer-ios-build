import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Remembers the last-read page of a PDF file so reopening it — from either
/// the standalone file viewer or the video player's inline file panel —
/// resumes where the student left off. One small JSON file per
/// (lectureId, fileId) under the app sandbox; never touches the encrypted
/// file itself.
class PdfPageCache {
  PdfPageCache._();

  static Future<File> _cacheFile(String lectureId, String fileId) async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/courses/$lectureId/files/$fileId');
    return File('${dir.path}/last_page.json');
  }

  static Future<int> load(String lectureId, String fileId) async {
    try {
      final f = await _cacheFile(lectureId, fileId);
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map;
        final page = (data['page'] as num?)?.toInt();
        if (page != null && page > 0) return page;
      }
    } catch (_) {}
    return 1;
  }

  static Future<void> save(String lectureId, String fileId, int page) async {
    try {
      final f = await _cacheFile(lectureId, fileId);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({'page': page}));
    } catch (_) {}
  }
}
