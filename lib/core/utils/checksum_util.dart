import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class ChecksumUtil {
  /// Computes SHA-256 over all .ts segment bytes concatenated in sorted order.
  /// Matches the Python encryptor's _compute_checksum.
  static Future<String> computeSegmentChecksum(String segmentsDir) async {
    final dir = Directory(segmentsDir);
    if (!await dir.exists()) return '';

    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.ts'))
        .cast<File>()
        .toList();

    files.sort((a, b) => a.path.compareTo(b.path));

    final builder = BytesBuilder();
    for (final file in files) {
      builder.add(await file.readAsBytes());
    }

    return sha256.convert(builder.toBytes()).toString();
  }
}
