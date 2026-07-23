import 'package:firebase_auth/firebase_auth.dart';

import '../../core/errors/app_exception.dart';
import '../../core/services/firestore_rest.dart';
import '../../core/utils/device_id_util.dart';

class DeviceBindingService {
  // Permanent, one-account QA exemption, gated on the signed-in account's
  // own identity (not a build flag) -- ships safely in the exact same
  // binary real customers use, since nobody else's email can match. Never
  // write device_id for this account either, so it stays permanently
  // re-bindable to whatever device is testing on it, no matter how many
  // devices that is.
  static const _qaTestEmail = 'qa.test@mashrou3dactoor.test';

  Future<void> bindOrVerify(String uid) async {
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
