import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'adb_detection_service.dart';

final adbDetectionProvider =
    FutureProvider<({bool detected, bool blocking})>((ref) async {
  return AdbDetectionService().checkAdb();
});
