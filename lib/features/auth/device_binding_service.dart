import '../../core/errors/app_exception.dart';
import '../../core/services/firestore_rest.dart';
import '../../core/utils/device_id_util.dart';

class DeviceBindingService {
  Future<void> bindOrVerify(String uid) async {
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
