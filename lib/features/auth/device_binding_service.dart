import 'package:firebase_auth/firebase_auth.dart';

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

  // Permanent, one-account QA exemption — unlike _skip above (a build flag
  // that would affect every real user of a build compiled with it), this is
  // gated on the signed-in account's own identity. It ships safely in the
  // exact same binary real customers use: nobody else's email can match, so
  // it can never exempt a real customer's device from binding. Never write
  // device_id for this account either, so it stays permanently re-bindable
  // to whatever device is testing on it, no matter how many devices that is.
  static const _qaTestEmail = 'qa.test@mashrou3dactoor.test';

  Future<void> bindOrVerify(String uid) async {
    if (_skip) return;
    if (FirebaseAuth.instance.currentUser?.email == _qaTestEmail) return;
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
