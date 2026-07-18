import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'root_detection_service.dart';

final rootDetectionProvider = FutureProvider<bool>((ref) async {
  return RootDetectionService().isDeviceRooted();
});
