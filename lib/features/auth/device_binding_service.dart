import '../../core/errors/app_exception.dart';
import '../../core/services/firestore_rest.dart';
import '../../core/utils/device_id_util.dart';

class DeviceBindingService {
  // TEMPORARY, test-build only — ephemeral cloud simulators (Codemagic App
  // Preview, Appetize, etc.) don't reliably persist Keychain storage between
  // sessions, so DeviceIdUtil.getDeviceId() can mint a fresh random ID every
  // time the simulator restarts. That makes device-binding permanently
  // unwinnable there: every relaunch looks like "a new device," no matter
  // how many times the real device_id field gets reset server-side. Only
  // ever set via --dart-define on a screenshot/test build — never in a real
  // release build.
  static const _skip = bool.fromEnvironment('SKIP_DEVICE_CHECK', defaultValue: false);

  Future<void> bindOrVerify(String uid) async {
    if (_skip) return;
    final deviceId = await DeviceIdUtil.getDeviceId();
    final data = await FirestoreRest.instance.getDoc('students', uid);

    if (data == null) {
      throw const ProfileNotFoundException(
        'Student profile not found. Contact your teacher.',
      );
    }

    final storedDeviceId = data['device_id'] as String?;

    if (storedDeviceId == null || storedDeviceId.isEmpty) {
      // First login on this device — bind it
      await FirestoreRest.instance.updateDoc('students', uid, {
        'device_id': deviceId,
        'device_registered_at': fsNow,
      });
    } else if (storedDeviceId != deviceId) {
      throw const DeviceMismatchException(
        'This account is registered on another device. Contact your teacher to reset.',
      );
    }
    // Same device — allowed through
  }
}
