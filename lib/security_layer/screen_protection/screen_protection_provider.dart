import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screen_protection_service.dart';

final screenProtectionServiceProvider = Provider<ScreenProtectionService>(
  (ref) => ScreenProtectionService(),
);

/// Stream of security event strings from the native side.
/// Consumers listen for "hdmi_connected", "recording_started", etc.
final securityEventsProvider = StreamProvider<String>((ref) {
  return ref.watch(screenProtectionServiceProvider).securityEvents;
});
