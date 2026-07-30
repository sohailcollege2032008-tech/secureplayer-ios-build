import '../../core/errors/app_exception.dart';
import '../../core/services/firestore_rest.dart';
import '../../core/utils/device_id_util.dart';

/// screenshot.demo@secureplayer.test — the FairPlay DRM demo/QA account, reused
/// across many separate Simulator/Codemagic/App-Preview runs, each of which can
/// legitimately report a different device_id. Exempted from device binding
/// entirely (mirrored server-side in getCourseKey/getFairplayLicense's own
/// DEVICE_BINDING_EXEMPT_UID) so testing never needs a manual "Reset Device"
/// between runs. Do not reuse this pattern for real student accounts.
const _kDeviceBindingExemptUid = 'ofN8y2OeUKg1Vu4q024jhzudM5j1';

class DeviceBindingService {
  Future<void> bindOrVerify(String uid) async {
    if (uid == _kDeviceBindingExemptUid) return;

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
